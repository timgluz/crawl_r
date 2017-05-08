require 'timeout'
require 'rugged'
require 'time'
require 'digest'

class GodepCrawler < Versioneye::Crawl

  A_GODEP_REGISTRY_URL = 'http://go-search.org/api'
  A_MAX_QUEUE_SIZE     = 500
  A_MAX_WAIT_TIME      = 180
  A_CLONERS_N          = 3
  MIN_MATCH_CONFIDENCE = 0.9

  def self.logger
    if !defined?(@@log) || @@log.nil?
      @@log = Versioneye::DynLog.new("log/godep.log", 10).log
    end
    @@log
  end

  #crawls all the packages got from go-search index
  def self.crawl_all
    @@license_matcher = LicenseMatcher.new
    @@license_cache   = ActiveSupport::Cache::MemoryStore.new(expires_in: 2.minutes)

    all_pkgs = fetch_package_index
    if all_pkgs.to_a.empty?
      logger.error "crawl_all: failed to retrieve packages at #{A_GODEP_REGISTRY_URL}"
      return false
    end

    all_pkgs.to_a.each {|pkg_id| crawl_one(pkg_id) }
    logger.info "crawl_all: done"
    true
  ensure
    cleanup
  end

  #crawls updates for a list of products
  #use case: pull newest versions for a project dependencies
  # package_ids = [Product.prod_key...]
  def self.crawl_by_product_ids(package_ids)
    if package_ids.to_a.empty?
      logger.error "crawl_products: the list of product_ids were empty"
      return false
    end

    @@license_matcher = LicenseMatcher.new
    @@license_cache   = ActiveSupport::Cache::MemoryStore.new(expires_in: 2.minutes)

    package_ids.to_a.each {|pkg_id| crawl_one(pkg_id) }
    logger.info "crawl_products: done"
    true
  ensure
    cleanup
  end

  def self.crawl_one(pkg_id)

    # pull metadata from go-search.org
    the_prod = Timeout::timeout(A_MAX_WAIT_TIME) { crawl_package(pkg_id) }
    if the_prod.nil?
      logger.error "crawl_one: failed to read packages data for: #{pkg_id}"
      return false
    end

    # clone the repo
    res = Timeout::timeout(A_MAX_WAIT_TIME) { clone_repo(pkg_id, the_prod[:group_id]) }
    if res.nil?
      logger.error "crawl_one: failed to clone #{pkg_id} from #{the_prod[:group_id]}"
      return false
    end

    # process cloned repo
    repo_idx = GitVersionIndex.new("tmp/#{pkg_id}")
    versions = Timeout::timeout(A_MAX_WAIT_TIME) { process_cloned_repo(repo_idx) }
    if versions.nil?
      logger.error "crawl_one: failed to read commit logs for #{pkg_id}"
      return false
    end

    the_prod.versions = versions #NB: it replaces old versions;
    #read license data from the repo
    add_version_licenses(the_prod, repo_idx)

    res = the_prod.save
    if res == true
     logger.info "crawl_one: saved #{pkg_id}"
    else
      logger.error "crawl_one: failed to save #{pkg_id} - #{the_prod.errors.full_messages}"
    end

    # process product versions and update the latest version
    ProductService.update_version_data( the_prod )

    res
  rescue => e
    logger.error "crawl_one: Failed to fetch and process repo #{pkg_id} - #{e.message.to_s}"
    logger.error e.backtrace.join('\n')
    return nil
  ensure
    res = system("rm -rf tmp/#{pkg_id}")
    logger.info "crawl_one: a #{pkg_id} repo deleted? #{res}"
  end

  #fetches package details from go-search,
  def self.crawl_package(pkg_id)
    pkg_dt = fetch_package_detail pkg_id
    if pkg_dt.nil?
      logger.error "Failed pull package details for #{pkg_id}"
      return
    end

    prod = init_product(pkg_id, pkg_dt)
    create_dependencies(pkg_id, pkg_dt[:Imports], pkg_dt[:testImports])
    create_version_link(prod, pkg_dt[:projectURL])

    prod.save
    prod
  end

  def self.fetch_package_index
    fetch_json "#{A_GODEP_REGISTRY_URL}?action=packages", 180
  end

  def self.fetch_package_detail(pkg_id)
    fetch_json "#{A_GODEP_REGISTRY_URL}?action=package&id=#{pkg_id}"
  end

  def self.clone_repo(pkg_id, pkg_url)
    Rugged::Repository.clone_at(pkg_url, "tmp/#{pkg_id}")
  rescue => e
    logger.error "failed to clone the repo: #{pkg_id} - #{pkg_url}"
    logger.error e.backtrace.join("\n")
    system("rm -rf tmp/#{pkg_id}") #remove carbage it may have created
    return nil
  end

  def self.process_cloned_repo(repo_idx)
    logger.info "process_cloned_repo: reading repo logs from #{repo_idx.dir.path}"

    repo_idx.build       #builds version tree from commit logs
    repo_idx.to_versions #transforms version tree into list of Version models
  rescue => e
    logger.error "process_cloned_repo: Failed to build commit version index"
    logger.error e.backtrace.join('\n')
    return nil
  end

  def self.add_version_licenses(the_prod, repo_idx)
    return false if the_prod.nil? or repo_idx.nil?

    the_prod.versions.each do |version|
      t0 = (Time.now.to_f * 1000).to_i
      license_files = repo_idx.get_license_files_from_sha(version[:sha1])
      t1 = (Time.now.to_f * 1000).to_i
      logger.info "#--------------------------------------------------------|------------"
      logger.info "add_version_licenses: get_license_files_from_sha took    |#{t1 - t0}ms"

      license_ids = match_licenses(license_files)
      t2 = (Time.now.to_f * 1000).to_i
      logger.info "add_version_licenses: match_licenses took                |#{t2 - t1}ms"

      license_ids.to_a.each {|spdx_id| create_single_license(version[:version], the_prod, spdx_id)}
      t3 = (Time.now.to_f * 1000).to_i
      logger.info "add_version_licenses: creating a new license model took  |#{t3 - t2}ms"
    end

    return true
  end

  def self.match_licenses(license_files)
    license_files.reduce([]) do |acc, commit_file|
      # try to re-use already detected results - next commit has probably same license
      file_md5 = Digest::MD5.hexdigest commit_file[:content]
      license_candidates = @@license_cache.fetch(file_md5) do
        @@license_matcher.match_text commit_file[:content]
      end

      if license_candidates.to_a.size > 0
        lic_id, score = license_candidates.first
        acc << @@license_matcher.to_spdx_id(lic_id) if score >= MIN_MATCH_CONFIDENCE
      end

      acc
    end
  end

  def self.create_single_license(version_label, the_prod, spdx_id)
    return if spdx_id.to_s.empty?

    version_label = the_prod[:version] if version_label.nil? or version_label == 'head'

    lic = License.find_or_create(the_prod[:language], the_prod[:prod_key], version_label, spdx_id, the_prod[:group_id])
    logger.debug "create_single_license: add #{spdx_id} license to the #{the_prod[:prod_key]}/#{version_label}"
    lic
  end

  #finds or creates product and updates information
  def self.init_product(pkg_id, pkg_dt)
    prod = Product.where(
      language: Product::A_LANGUAGE_GO,
      prod_type: Project::A_TYPE_GODEP,
      prod_key: pkg_id
    ).first_or_create

    prod.update({
      name: pkg_dt[:Name],
      name_downcase: pkg_dt[:Name].to_s.downcase,
      downloads: (pkg_dt[:StarCount] + pkg_dt[:StaticRank] + 1),
      description: pkg_dt[:Description],
      group_id: pkg_dt[:ProjectURL] #one repo may include many GOdep packages ~ AWS stuff and used for passing urls to cloning process
    })

    prod
  end

  def self.create_dependencies(pkg_id, dependencies, test_dependencies)
    deps = []
    dependencies.to_a.each {|dep_id| deps << create_dependency(pkg_id, dep_id, Dependency::A_SCOPE_COMPILE) }
    test_dependencies.to_a.each {|dep_id| deps << create_dependency(pkg_id, dep_id, Dependency::A_SCOPE_DEVELOPMENT) }

    deps
  end

  def self.create_dependency(pkg_id, dep_id, the_scope)
    dep = Dependency.where(prod_type: Project::A_TYPE_GODEP, prod_key: pkg_id, dep_prod_key: dep_id).first
    return dep if dep

    dep = Dependency.create({
      prod_type: Project::A_TYPE_GODEP,
      language: Product::A_LANGUAGE_GO,
      prod_key: pkg_id,
      prod_version: '*',
      dep_prod_key: dep_id,
      scope: the_scope,
      version: '*'
    })

    unless dep.errors.empty?
      log.error "create_dependency: failed to save dependency #{dep_id} for #{pkg_id},\n #{dep.errors.full_messages}"
    end
    dep
  end

  def self.create_version_link(prod, url, name = "Repository")
    link = Versionlink.where(
      language: Product::A_LANGUAGE_GO,
      prod_type: Project::A_TYPE_GODEP,
      link: url
    ).first
    return link if link

    Versionlink.create_versionlink prod.language, prod.prod_key, nil, url, name
  end

  def self.cleanup
    system("rm -rf tmp/*")
  end
end
