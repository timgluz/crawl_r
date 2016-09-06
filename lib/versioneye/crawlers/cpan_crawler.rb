class CpanCrawler < Versioneye::Crawl

  A_API_URL       = 'http://api.metacpan.org'
  A_LANGUAGE_PERL = Product::A_LANGUAGE_PERL
  A_TYPE_CPAN     = Project::A_TYPE_CPAN
  A_SCROLL_TTL    = '2m'

  def self.logger
    if !defined?(@@log)
      @@log = Versioneye::DynLog.new("log/cpan.log", 10).log
    end
    @@log
  end


  #iterates over paginated results
  def self.crawl(all = true, from_days_ago = 2, to_days_ago = nil)
    logger.debug("crawl: starting...")

    page_nr = 1
    scroll_id = nil
    page = start_release_scroll(all, from_days_ago, to_days_ago)

    while page
      logger.debug "crawl_all: page.#{page_nr}"
      unless page.is_a?(Hash)
        #quite when response was anything than Hashmap
        log.error "crawl: got malformed response from first scroll request:\n #{page}"
        break
      end

      scroll_id = page[:_scroll_id] if page.has_key?(:_scroll_id)
      logger.debug "crawl: new scroll_id `#{scroll_id}`"

      crawl_release_page(page)
      page_nr += 1
      break if page.is_a?(Hash) and page[:hits].empty?

      page = fetch_release_scroll(scroll_id)
    end

    logger.debug "crawl: done"
    return true
  ensure
    #remove scrolling session
    HTTParty.delete(
      "#{A_API_URL}/v0/release/_search",
      { body: "[#{scroll_id}]" }
    )
  end

  #crawl release details for each item in the search results
  def self.crawl_release_page(release_page)
    logger.debug "crawl_release_page: crawling items from release_page"
    return unless release_page.is_a?(Hash)
    return unless release_page.has_key?(:hits)
    return unless release_page[:hits].has_key?(:hits)

    res = release_page[:hits][:hits]
    res.each {|hit| crawl_release(hit[:fields][:author], hit[:fields][:name]) }
  end

  def self.crawl_release(author_id, release_id)
    author_doc = fetch_author_details(author_id)
    if author_doc.nil?
      logger.error "crawl_release: failed to fetch details for the author `#{author_id}`"
      return
    end

    release_doc = fetch_release_details(author_id, release_id)
    if release_doc.nil?
      logger.error "crawl_release: failed to fetch release info for #{author_id}/#{release_id}"
      return
    end

    module_id = to_module_name(release_doc[:distribution])
    module_doc = fetch_module_details(module_id)
    if module_doc.nil?
      logger.warn "crawl_release: no module #{module_id} for release #{author_id}/#{release_id} - will fallback to release data."
      module_doc = {
        version: release_doc[:version],
        description: release_doc[:abstract]
      }
    end

    logger.debug "crawl_release: saving #{author_id}/#{release_id}"
    persist_release(author_doc, release_doc, module_doc)
  end

  def self.start_release_scroll(all, from_days_ago, to_days_ago)
    releases_url = "#{A_API_URL}/v0/release/_search?scroll=#{A_SCROLL_TTL}"

    releases_query = {
      "query" => {"match_all" => {}},
      "filter" => {
        "and" => [
          {"term" => { "authorized" => true }}
        ]
      },
      "fields"  => [ "author", "name"],
      "sort"    => [{ "date" => "asc" }],
      "size"    => 100
    }

    if all == false
      from = (from_days_ago.to_i > 0 ? "now-#{from_days_ago}d/d" : "now-1d/d")
      to   = (to_days_ago.to_i > 0 ?  "now-#{to_days_ago}d/d" : "now/d")

      releases_query["query"] = {
        "range" => {"date" => {"gte" => from, "lt"  => to}}
      }

    end

    query_json = JSON.dump(releases_query)
    post_json(releases_url, {body: query_json})
  end

  def self.fetch_author_details(author_id)
    author_url = "#{A_API_URL}/v0/author/#{author_id}"
    fetch_json author_url
  end

  def self.fetch_release_details(author_id, release_id)
    release_url = "#{A_API_URL}/v0/release/#{author_id}/#{release_id}"
    fetch_json release_url
  end

  def self.fetch_module_details(module_id)
    module_url = "#{A_API_URL}/v0/module/#{module_id}"
    fetch_json module_url
  end


  def self.fetch_release_scroll(scroll_id)
    scroll_url = "#{A_API_URL}/_search/scroll?scroll=#{A_SCROLL_TTL}&scroll_id=#{scroll_id}"
    fetch_json scroll_url
  end

  def self.persist_release(author_doc, release_doc, module_doc)

    #when package doesnt provide modules, then translate name to module name
    if release_doc[:provides].is_a?(Array) and release_doc[:provides].size > 0
      modules = release_doc[:provides]
    elsif release_doc[:provides].is_a?(Hash) and release_doc[:provides].keys.size > 0
      modules = release_doc[:provides].keys.map{|x| x.to_s}
    else
      default_module = to_module_name( release_doc[:distribution] )
      logger.debug "persist_release: using default module name #{default_module}"
      modules = [default_module]
    end

    #saves each module as own product
    prods = modules.reduce([]) do |acc, prod_key|
      acc << upsert_product(author_doc, release_doc, module_doc, prod_key)
      acc
    end

    prods
  end

  def self.upsert_product(author_doc, release_doc, module_doc, prod_key)
    prod = Product.find_or_initialize_by(language: A_LANGUAGE_PERL, prod_type: A_TYPE_CPAN, prod_key: prod_key)

    release_version_label = release_doc[:version].to_s.gsub(/\Av/i, '')
    latest_version_label  = module_doc[:version].to_s.gsub(/\Av/i, '')
    artifact_id = "#{release_doc[:author]}/#{release_doc[:name]}"
    parent_id   = if release_doc[:main_module]
                    release_doc[:main_module]
                  else
                    to_module_name(release_doc[:distribution]) #use distribution name as parent id
                  end

    prod.update({
      name: prod_key,
      group_id: release_doc[:author],       # MetaCPAN organizes packages under usernames
      parent_id: parent_id,                 # refers to main modules
      artifact_id: artifact_id,             # ID to get data from releases API
      version: latest_version_label,
			description: module_doc[:description]
    })
    if prod.save
      logger.info "upsert_product: add new product #{prod.to_s}"
    else
      logger.warn "upsert_product: failed to save #{prod.to_s} - #{prod.errors.full_messages.to_s}"
    end

    upsert_version(prod, release_version_label, release_doc)

    release_doc[:dependency].to_a.each {|dep_doc| upsert_dependency(dep_doc, prod_key, release_version_label)}
    release_doc[:resources].to_a.each do |title, url_doc|
      url = if url_doc.is_a?(String)
              url_doc
            elsif url_doc.is_a?(Array)
              url_doc.first
            elsif url_doc.is_a?(Hash) and url_doc.has_key?(:web)
              url_doc[:web]
            elsif url_doc.is_a?(Hash) and url_doc.has_key?(:url)
              url_doc[:url]
            else
              nil
            end

      upsert_version_link(prod, release_version_label, title, url)
    end
    upsert_version_download(prod, release_version_label, release_doc)
    upsert_version_license(prod, release_version_label, release_doc)

    if author_doc
      upsert_author(prod, release_version_label, author_doc)
    end

		if release_doc.has_key?(:metadata)
			upsert_contributors(prod, release_version_label, release_doc[:metadata][:x_contributors])
		end

    prod
  end

  def self.upsert_version(prod, version_label, release_doc)
    version_db = prod.versions.find_or_initialize_by(version: version_label)

    release_date = safely_to_date(release_doc[:date])
    version_db.update({
      released_at: release_date,
      released_string: release_doc[:date],
      status: release_doc[:maturity]
    })

    version_db
  end

  def self.safely_to_date(date_txt)
    DateTime.parse date_txt
  rescue => e
    logger.error "safely_to_date: failed to parse date string `#{date_txt}`\n#{e.message}"
    nil
  end

	def self.upsert_contributors(prod, version_label, contributors)
		return if contributors.nil?

		contributors.reduce([]) do |acc, contributor_line|
			tkns = contributor_line.to_s.gsub(/\<|\>/, '').split(/\s+/)
			next if tkns.empty?

			author_doc = {
					email: [tkns.pop],
					asciiname: tkns.join(' ')
			}

			contrib = upsert_author(prod, version_label, author_doc, 'contributor')
      acc << contrib if contrib
      acc
		end
	end

  def self.upsert_author(prod, version_label, author_doc, role = 'author')
    email = author_doc[:email].first
		author = Developer.find_or_initialize_by(
			language: A_LANGUAGE_PERL,
			prod_key: prod[:prod_key],
			version: version_label,
			email: email
		)

		role.to_s.downcase!
    website = (author_doc.has_key?(:website) ? author_doc[:website].first : nil)
    author.update({
			organization: author_doc[:pauseid],
      name: author_doc[:asciiname],
      homepage: website,
      role: role,
			contributor: (role == 'contributor')
    })
    author.save

    author
  end


  def self.upsert_dependency(dep_doc, prod_key, version_label)
    dep = Dependency.find_or_initialize_by(
      prod_type: A_TYPE_CPAN,
      language: A_LANGUAGE_PERL,
      prod_key: prod_key,
      prod_version: version_label,
      dep_prod_key: dep_doc[:module]
    )

    dep_version = dep_doc[:version].to_s.gsub(/\Av/i, '')
    dep_scope   = match_dependency_scope(dep_doc[:phase])
    dep[:version] = dep_version
    dep[:scope]   = dep_scope

    dep.save
    dep.update_known
    dep
  end

  def self.upsert_version_link(prod, version_label, title, url)
    return if url.to_s.empty?

    Versionlink.find_or_create_by(
      language: prod.language,
      prod_key: prod.prod_key,
      version_id: version_label,
      link: url,
      name: title.to_s
    )
  end

  def self.upsert_version_download(prod, version_label, release_doc)
    Versionarchive.find_or_create_by(
      language: A_LANGUAGE_PERL,
      prod_key: prod.prod_key,
      version_id: version_label,
      name: release_doc[:archive],
      link: release_doc[:download_url]
    )
  end

  def self.upsert_version_license(prod, version_label, license_id)
    license_dt = match_license(license_id)
    version_label = version_label.to_s.strip
    version = (version_label.empty? ? prod[:version] : version_label)

    lic_db = License.find_or_create_by(
      language: A_LANGUAGE_PERL,
      prod_key: prod.prod_key,
      version: version,
      name: (license_dt[:name] || license_dt[:spdx_id])
    )
    lic_db[:url] = license_dt[:url]
    lic_db[:spdx_id] = license_dt[:spdx_id]

    lic_db.save
    lic_db
  end

  def self.match_dependency_scope(scope_lbl)
    scope_lbl = scope_lbl.to_s.downcase
    case scope_lbl
    when 'develop'
      Dependency::A_SCOPE_DEVELOPMENT
    when 'build'
      Dependency::A_SCOPE_COMPILE
    else
      scope_lbl
    end
  end

  def self.to_module_name(dist_name)
    dist_name.to_s.gsub(/\-/, '::')
  end


	#source: http://blogs.perl.org/users/kentnl_kent_fredric/2012/05/ensure-abstract-and-license-fields-in-your-meta.html
  def self.match_license(license_id)
    case license_id.to_s.downcase
    when 'perl_5'
      {
        spdx_id: 'Artistic-1.0-Perl',
        url: 'http://dev.perl.org/licenses/artistic.html',
      }
    when 'apache', 'apache_2_0'
      {
        spdx_id: 'Apache-2.0',
        url: 'https://opensource.org/licenses/Apache-2.0'
      }
    when 'apache_1_1'
      {
        spdx_id: 'Apache-1.1',
        url: 'https://opensource.org/licenses/Apache-1.1'
      }

    when 'artistic', 'artistic_1'
      {
        spdx_id: 'Artistic-1.0',
        url: 'https://opensource.org/licenses/Artistic-1.0'
      }
    when 'artistic_2'
      {
        spdx_id: 'Artistic-2.0',
        url: 'https://opensource.org/licenses/artistic-license-2.0'
      }
    when 'bsd'
      {
        spdx_id: 'BSD-Source-Code',
        url: 'https://spdx.org/licenses/BSD-Source-Code.html'
      }
    when 'unrestricted'
			{
				spdx_id: 'CC0-1.0',
				url: 'https://creativecommons.org/publicdomain/zero/1.0/legalcode'
			}
    when 'freebsd'
      {
        spdx_id: 'BSD-2-Clause',
        url: 'https://opensource.org/licenses/BSD-2-Clause'
      }
		when 'gfdl_1_2'
      {
				spdx_id: 'GFDL-1.1',
				url: 'https://www.gnu.org/licenses/old-licenses/fdl-1.1.txt'
			}
    when 'gfdl_1_3'
			{
				spdx_id: 'GFDL-1.3',
				url: 'https://www.gnu.org/licenses/fdl-1.3.txt'
			}
    when 'gpl_1'
			{
				spdx_id: 'GPL-1.0',
				url: 'https://www.gnu.org/licenses/old-licenses/gpl-1.0-standalone.html'
			}
    when 'gpl_2'
			{
				spdx_id: 'GPL-2.0',
				url: 'https://opensource.org/licenses/GPL-2.0'
			}
    when 'gpl', 'gpl_3'
			{
				spdx_id: 'GPL-3.0',
				url: 'https://opensource.org/licenses/GPL-3.0'
			}
    when 'lgpl', 'lgpl_2_1'
			{
				spdx_id: 'LGPL-2.1',
				url: 'https://opensource.org/licenses/LGPL-2.1'
			}
    when 'lgpl_3_0'
      {
				spdx_id: 'LGPL-3.0',
				url: 'https://opensource.org/licenses/LGPL-3.0'
			}
    when 'mit'
			{
				spdx_id: 'MIT',
				url: 'https://opensource.org/licenses/MIT'
			}
    when 'mozilla_1_0'
			{
				spdx_id: 'MPL-1.0',
				url: 'https://opensource.org/licenses/MPL-1.0'
			}
    when 'mozilla', 'mozilla_1_1'
			{
				spdx_id: 'MPL-1.1',
				url: 'https://opensource.org/licenses/MPL-1.1'
			}
    when 'openssl'
			{
				name: 'OpenSSL license',
				url: 'https://www.openssl.org/source/license.txt'
			}
    when 'qpl_1_0'
			{
				spdx_id: 'QPL-1.0',
				url: 'https://opensource.org/licenses/QPL-1.0'
			}
    when 'ssleay'
			{
				name: 'Original SSLeay License',
				url: 'http://h41379.www4.hpe.com/doc/83final/ba554_90007/apcs02.html'
			}
		when 'sun'
			{
				spdx_id: 'SISSL',
				url: 'https://opensource.org/licenses/sisslpl'
			}
    when 'zlib'
			{
				spdx_id: 'Zlib',
				url: 'http://www.zimbra.com/legal/zimbra-public-license-1-4/'
			}
    else
      {
        name: 'Unknown',
        url: nil,
        spdx_id: nil,
      }
    end
  end
end
