class NugetCrawler < Versioneye::Crawl


  A_NUGET_URL       = "https://api.nuget.org/v3"
  A_CATALOG_PATH    = "/catalog0/index.json"
  A_DOWNLOAD_URL    = "https://www.nuget.org/api/v2/package"
  A_PACKAGE_URL     = "https://www.nuget.org/packages"
  A_PROFILE_URL     = "https://www.nuget.org/profiles"
  A_LANGUAGE_CSHARP = Product::A_LANGUAGE_CSHARP
  A_TYPE_NUGET      = Project::A_TYPE_NUGET


  def self.logger
    if !defined?(@@log) || @@log.nil?
      @@log = Versioneye::DynLog.new("log/nuget.log", 10).log
    end
    @@log
  end

  def self.parse_date_string( dt_txt )
    DateTime.parse dt_txt
  rescue
    logger.error "Failed to parse datetime from string: `#{dt_txt}`"
    return nil
  end

  def self.is_same_date(dt_txt1, dt_txt2)
    return false if dt_txt1.to_s.empty? or dt_txt2.to_s.empty?

    dt1 = parse_date_string dt_txt1
    dt2 = parse_date_string dt_txt2
    return false if dt1.nil? or dt2.nil?

    dt1.strftime('%Y-%m-%d') == dt2.strftime('%Y-%m-%d')
  end

  def self.crawl_last_x_days( x_days = 10 )
    x_days.times.each do |xd|
      today = DateTime.now
      xday = today - xd
      crawl( xday.strftime("%F") )
    end
  end

  # crawls all the items if date_txt is nil
  # otherwise will only crawl catalogs published on the date_txt
  # date_txt format: YYYY-mm-dd or any other format supported by DateTime.parse
  def self.crawl(date_txt = nil)
    catalog = self.fetch_json("#{A_NUGET_URL}#{A_CATALOG_PATH}")
    if catalog.nil?
      self.logger.error "crawl: Failed to fetch the Nuget catalog."
      return nil
    end

    pages = if date_txt.to_s.empty?
              logger.info "NugetCrawler: going to crawl all the catalogs."
              catalog[:items]
            else
              logger.info "NugetCrawler: going to crawl only #{date_txt} catalogs"
              catalog[:items].keep_if {|x| is_same_date(date_txt, x[:commitTimeStamp])}
            end
    crawl_catalog_pages(pages)
    logger.info "NugetCrawler: done."
  end

  def self.crawl_catalog_pages(item_list)
    if item_list.nil? or item_list.empty?
      self.logger.warn "crawl_catalog_items: The list of Nuget catalog was empty."
      return
    end

    item_list.to_a.each { |the_page| crawl_catalog_page(the_page) }
  end

  def self.crawl_catalog_page(the_page)
    if the_page.nil?
      self.logger.warn "crawl_catalog_page: no page document"
      return
    end

    self.logger.info "Crawling catalog page: #{the_page[:@id]} - items: #{the_page[:count]}"

    page_items = fetch_json the_page[:@id]
    if page_items.nil?
      logger.warn "crawl_catalog_page: failed to fetch items on the catalog page: #{the_page}"
      return
    end

    page_items[:items].to_a.each {|the_package| crawl_package(the_package) }
  end

  def self.crawl_package( the_package )
    if the_package.nil?
      logger.warn "crawl_package: the package document was empty."
      return
    end

    doc = fetch_json the_package[:@id]
    if doc.nil?
      logger.warn "crawl_package: failed to fetch package details from: #{the_package}"
      return
    end

    save_product_info doc
  rescue => e
    self.logger.error "ERROR in crawl_package: #{e.message}"
    self.logger.error e.backtrace.join("\n")
    nil
  end


  def self.save_product_info(product_doc)
    version_number = product_doc[:version]
    product = upsert_product product_doc
    unless product
      logger.error "save_product_info: failed to save #{product_doc}"
      return
    end

    if create_new_version(product, product_doc)
      create_dependencies(product, product_doc, version_number)
      create_download(product, version_number)
      create_versionlinks(product, product_doc, version_number)
      create_license(product, product_doc[:licenseUrl], version_number)
      create_authors(product, product_doc[:authors], version_number)

      logger.info "-- New Nuget Package: #{product.prod_key} : #{version_number} "
      CrawlerUtils.create_newest( product, version_number, logger )
      CrawlerUtils.create_notifications( product, version_number, logger )
    else
      update_release_date product, product_doc
    end

    upsert_artefact(product, version_number)
    product
  end


  def self.update_release_date product, product_doc
    version_number = product_doc[:version]
    db_version = product.version_by_number version_number

    publish_date_label = nil
    if product_doc[:listed] == true
      publish_date_label = product_doc[:published] #when it was released publicly, has old values for unlisted ones
    else
      publish_date_label = product_doc[:created] #when it was submitted to Nuget registry
    end

    release_dt = parse_date_string(publish_date_label)
    #even if listed package has very old release date, then fallback to created
    if release_dt.nil? or release_dt.year < 2000
      publish_date_label = product_doc[:created]
      release_dt = parse_date_string( publish_date_label )
    end

    db_version.released_at = release_dt
    db_version.released_string = publish_date_label
    db_version.save
    self.logger.info "Updated #{product.prod_key}:#{version_number} with release date #{publish_date_label}"
  rescue => e
    self.logger.error "ERROR in crawl_package: #{e.message}"
    self.logger.error e.backtrace.join("\n")
  end


  #creates a new document or updates existing one
  def self.upsert_product(doc)

    product = Product.where(
      language: A_LANGUAGE_CSHARP,
      prod_key: doc[:id]
    ).first

    unless product
      product = Product.new({
        language: A_LANGUAGE_CSHARP,
        prod_type: A_TYPE_NUGET,
        prod_key: doc[:id],
        reindex: true
      })
    end

    sha_algo = doc[:packageHashAlgorithm].to_s.strip.downcase
    #nb! Product.version is set by another background worker
    product.update({
      prod_key_dc: doc[:id].to_s.downcase,
      name: doc[:id],
      name_downcase: doc[:id].to_s.downcase,
      description: ( doc[:description] or doc[:summary] ),
      sha256: (sha_algo == 'sha256') ? doc[:packageHash] : nil,
      sha512: (sha_algo == 'sha512') ? doc[:packageHash] : nil,
      tags: doc[:tags].to_a
    })

    product.save
    product
  end


  # saves new product version and returns true if version is new
  # returns false if the version exist already in the db.
  def self.create_new_version(product, product_doc)
    version_number = product_doc[:version]
    db_version = product.version_by_number version_number
    if db_version # exist then skip this version
      log.info "create_new_version: version #{version_number} already exists for #{product[:prod_key]}"
      return false
    end

    if product_doc[:listed] == true
      publish_date_label = product_doc[:published] #when it was released publicly, has old values for unlisted ones
    else
      publish_date_label = product_doc[:created] #when it was submitted to Nuget registry
    end

    release_dt = parse_date_string(publish_date_label)
    #even if listed package has very old release date, then fallback to created
    if release_dt.nil? or release_dt.year < 2000
      publish_date_label = product_doc[:created]
      release_dt = parse_date_string( publish_date_label )
    end

    version_db = Version.new({
      version: product_doc[:version],
      released_at: release_dt,
      released_string: publish_date_label,
      status: (product_doc[:isPreRelease] ? "prerelease" : "stable" )
    })

    case product_doc[:packageHashAlgorithm]
    when /sha512/i
      version_db[:sha512] = product_doc[:packageHash]
    when /sha256/i
      version_db[:sha256] = product_doc[:packageHash]
    end

    product.versions.push version_db
    product.reindex = true
    product.save
  end


  #product = initialized Product model, product_doc = product data from NugetAPI
  def self.create_dependencies(product, product_doc, version_number)
    return if product_doc[:dependencyGroups].nil?

    product_doc[:dependencyGroups].each do |dep_group|
      #saves dependencies from target grouping
      dep_group[:dependencies].to_a.each do |dep|
        create_dependency(product, version_number, dep, dep_group[:targetFramework])
      end
    end
  end


  def self.create_dependency(product, version_number, dep, target = "")
    dep_db = Dependency.find_by(
      A_LANGUAGE_CSHARP, product.prod_key, version_number, dep[:id], dep[:range], dep[:id]
    )

    return dep_db unless dep_db.nil?

    dep_db = Dependency.new({
      name: dep[:id],
      version: dep[:range],
      dep_prod_key: dep[:id],
      prod_key: product.prod_key,
      prod_version: version_number,
      scope: Dependency::A_SCOPE_COMPILE,
      prod_type: A_TYPE_NUGET,
      language: A_LANGUAGE_CSHARP,
      targetFramework: target
    })

    dep_db.save
    dep_db.update_known

    logger.info "#-- create a new Nuget dependency: #{dep_db}"
    dep_db
  end


  def self.create_download(product, version_number)
    archive_db = Versionarchive.new({
      language: product.language,
      prod_key: product.prod_key,
      version_id: version_number,
      name: "Nupkg download",
      link: "#{A_DOWNLOAD_URL}/#{product.prod_key}/#{version_number}"
    })
    Versionarchive.create_if_not_exist_by_name(archive_db)
  end


  def self.create_versionlinks(product, product_doc, version_number)
    repo_link = "#{A_PACKAGE_URL}/#{product.prod_key}"
    Versionlink.create_versionlink(
      product.language, product.prod_key, version_number, repo_link, 'Repository'
    )

    if product_doc[:projectUrl]
      Versionlink.create_versionlink(
        product.language, product.prod_key, version_number, product_doc[:projectUrl], 'Homepage'
      )
    end

    product
  end


  def self.create_license(product, license_url, version_number)
    return if license_url.nil?

    license = License.find_or_create_by(
      name: "Nuget Unknown",
      language: product.language,
      prod_key: product.prod_key,
      version: version_number,
      url: license_url
    )

    license.save
    license
  end


  def self.create_authors(product, authors_csv, version_number)
    return if authors_csv.to_s.empty?

    authors = authors_csv.split(',')
    authors.each {|author_name| create_author(product, version_number, author_name) }
  end


  def self.create_author(product, version_number, author_name)
    return if author_name.to_s.empty?

    devs = Developer.find_by(
      product.language, product.prod_key, version_number, author_name
    )
    return unless devs.nil? or devs.empty?

    Developer.new({
      language: product.language,
      prod_key: product.prod_key,
      version: version_number,
      name: author_name,
      role: 'author'
    }).save
  end


  def self.upsert_artefact(product, version)
    if product.sha512
      upsert_artefact_sha product, version, product.sha512, 'sha512'
    end
    if product.sha256
      upsert_artefact_sha product, version, product.sha256, 'sha256'
    end
  end


  def self.upsert_artefact_sha(product, version, sha, sha_method)
    artefact = Artefact.find_or_create_by(
                  :language   => product.language,
                  :prod_key   => product.prod_key,
                  :version    => version,
                  :prod_type  => product.prod_type,
                  :packaging  => 'nupkg',
                  :sha_value  => sha,
                  :sha_method => sha_method )
    artefact.save
  end


end
