class LicenseCrawler < Versioneye::Crawl


  A_SOURCE_GMB = 'GMB'    # GitHub Master Branch
  A_SOURCE_G   = 'GITHUB' # GitHub Master Branch

  LICENSE_FILES = ['LICENSE.md', 'LICENSE.txt', 'LICENSE', 'LICENCE', 'MIT-LICENSE',
                   'license.md', 'licence.md', 'UNLICENSE.md', 'README.md']


  def self.logger
    if !defined?(@@log) || @@log.nil?
      @@log = Versioneye::DynLog.new("log/license.log", 10).log
    end
    @@log
  end


  def self.fetch url
     HTTParty.get url, { timeout: 5 }
  rescue
    logger.error "failed to fetch data from #{url}"
    nil
  end

  def self.to_uri url_text
    URI.parse url_text.to_s.strip

  rescue
    logger.error "Not valid url: #{url_text}"
    nil
  end

  def self.parse_url url_text
    uri = to_uri url_text
    return nil if uri.nil?
      
    uri.to_s.strip
  end

  # it fetches license file from url and then tries to match it with
  # all the OSS licenses on SPDX and uses best result as license ID
  # params:
  #   licenses - [License], an array of license models, which should be processes
  #   min_confidence - Float[0.0,1.0], a minimum score which is acceptable for updates
  def self.crawl_unidentified_urls(licenses, min_confidence = 0.9, update = false)
    logger.info "crawl_unidentified_urls: initializing a LicenseMatcher."
    #initialization of LicenseMatcher takes long time
    lic_matcher = LicenseMatcher.new
    url_cache   = ActiveSupport::Cache::MemoryStore.new(expires_in: 2.minutes)

    if lic_matcher.licenses.empty?
      logger.error "crawl_unidentified_urls: failed to initialize LicenseMatcher"
      return
    end

    n, failed = 0,0

    logger.info "crawl_unidentified_urls: starting crawling process."
    licenses.to_a.each do |license|
      n += 1
      failed += process_license( license, lic_matcher, url_cache, min_confidence, update ).to_i
    end

    logger.info "crawl_unidentified_urls: done! crawled #{n} licenses, skipped: #{failed}"
  end


  def self.process_license( license, lic_matcher, url_cache, min_confidence, update )
    the_url = parse_url(license[:url])
    if the_url.to_s.empty?
      logger.error "#{license.to_s} - not valid url #{license[:url]}"
      return 0
    end

    # First try to match by url without doing http request
    lic_id, score = lic_matcher.match_url(the_url)

    if lic_id.nil?
      lic_id, score = url_cache.fetch(the_url) do
                        logger.info "\tprocess_license: going to fetch license text from #{the_url}"
                        fetch_and_match_license_url(lic_matcher, license.to_s, the_url)
                      end
    end

    if lic_id.nil?
      logger.warn "\tprocess_license: detected no licenses for #{the_url}"
      return 1
    end

    if score >= min_confidence
			#licenseID == downcased SPDX_ID
      spdx_id = lic_matcher.to_spdx_id(lic_id)
      license.name = spdx_id
      license.spdx_id = spdx_id
      license.comments = "#{license.language}_license_crawler_update"
      res = license.save if update
      if res
        logger.info "\tprocess_license: updated #{license.to_s} SPDX ID #{license.spdx_id} from #{the_url}"
      end

    else
      logger.info "\tprocess_license: -- too low confidence #{score} for #{license.spdx_id}: #{the_url}"
    end

    return 0
  rescue => e
    logger.error "process_license: ERROR in process_license - #{e.message}"
    0
  end


  # fetches license file by url and uses LicenseMatcher to match the body of licence text
  # to detect matching SPDX_ID;
  # arguments:
  #   lic_matcher - a LicenseMatcher instance
  #   prod_id - license id, it used only for logging
  #   url - string with valid url
  # returns:
  #  [spdx_id, confidence] - 1st of best matching licenses
  def self.fetch_and_match_license_url(lic_matcher, prod_id, url = nil, min_confidence = 0.9)

    the_url = parse_url(url.to_s)
    if the_url.to_s.empty?
      logger.warn "\tfetch_match: no url for #{prod_id}."
      return []
    end

    res = fetch the_url
    if res.nil? or res.code != 200
      logger.error "\tfetch_match: failed request #{res.try(:code)} - #{prod_id}, #{url}"
      return []
    end

    lic_text = res.body
    #pre-process result
    case res.headers["content-type"]
    when /text\/plain/i
      lic_text = lic_matcher.preprocess_text(lic_text)
    when /text\/html/i
      lic_text = lic_matcher.preprocess_text lic_matcher.preprocess_html(lic_text)
    else
			#someone psoted link to pdf, docx, etc
      logger.error "\tfetch_match: unsupported content-type #{res.headers['content-type']} - #{prod_id}, #{url}"
			return []
    end
    
    matches = lic_matcher.match_text(lic_text, 3, true)

    if matches.nil? or matches.empty?
      logger.warn "\tfetch_match: no match for #{prod_id}, #{the_url}"
      return []
    end

    logger.debug "\tfetch_match: matches for #{prod_id} => #{matches} #{the_url}"
    matches.first
  end


  def self.crawl language = nil
    links_uniq = []
    links = []
    if language
      links = Versionlink.where(:link => /http.+github\.com\/\S*\/\S*[\/]*$/i, :language => language)
    else
      links = Versionlink.where(:link => /http.+github\.com\/\S*\/\S*[\/]*$/i)
    end
    logger.info "found #{links.count} github links"
    links.each do |link|
      ukey = "#{link.language}::#{link.prod_key}::#{link.link}"
      next if links_uniq.include?(ukey)

      links_uniq << ukey
      product = fetch_product link
      next if product.nil?

      licenses = License.where({:language => link.language, :prod_key => link.prod_key,
        :version => nil, :source => A_SOURCE_GMB })
      next if licenses && !licenses.empty?

      # This step is temporary for the init crawl
      licenses = product.licenses true
      next if licenses && !licenses.empty?

      process link, product
    end
    logger.info "found #{links_uniq.count} unique  github links"
  end


  def self.process link, product, version = nil
    repo_name = link.link
    repo_name = repo_name.gsub(/\?.*/i, "")
    repo_name = repo_name.gsub(/http.+github\.com\//i, "")
    if repo_name.match(/\/$/)
      repo_name = repo_name.gsub(/\/$/, "")
    end
    sps = repo_name.split("/")
    if sps.count > 2
      logger.info " - SKIP #{repo_name}"
      return
    end

    process_github_master repo_name, product, version
  end


  def self.process_github_master repo_name, product, version = nil
    process_github( repo_name, 'master', product, nil )
  end


  def self.process_github( repo_name, branch = "master", product = nil, version = nil )
    return nil if repo_name.to_s.empty?
    return nil if product.nil?

    LICENSE_FILES.each do |lf|
      raw_url = "https://raw.githubusercontent.com/#{repo_name}/#{branch}/#{lf}".gsub("\n", "").gsub("\t", "").strip
      raw_url = URI.encode raw_url
      license_found = process_url( raw_url, product, version )
      return true if license_found
    end
    false
  end


  def self.process_url raw_url, product, version = nil
    resp = HttpService.fetch_response raw_url
    return false if resp.code.to_i != 200

    lic_info = recognize_license resp.body, raw_url, product, version
    return false if lic_info.nil?
    return true
  rescue => e
    logger.error e.message
    logger.error e.backtrace.join("\n")
    false
  end


  def self.recognize_license content, raw_url, product, version = nil
    return nil if content.to_s.strip.empty?

    content = prepare_content content
    return nil if content.to_s.strip.empty?


    if is_widen_commercial_license?( content )
      logger.info " -- Widen Commercial License Agreement at #{raw_url} --- "
      find_or_create( product, 'Widen Commercial License Agreement', raw_url, version )
      return 'Widen Commercial License Agreement'
    end

    if is_new_bsd?( content )
      logger.info " -- New BSD License found at #{raw_url} --- "
      find_or_create( product, 'New BSD', raw_url, version )
      return 'BSD-3-Clause'
    end

    if is_BSD_2_clause?( content )
      logger.info " -- BSD 2-clause License found at #{raw_url} --- "
      find_or_create( product, 'BSD 2-clause', raw_url, version )
      return 'BSD-2-Clause'
    end

    if is_gpl_30?( content ) || is_gpl_30_short?( content )
      logger.info " -- GPL-3.0 found at #{raw_url} --- "
      find_or_create( product, 'GPL-3.0', raw_url, version )
      return 'GPL-3.0'
    end

    if is_gpl_20?( content )
      logger.info " -- GPL-2.0 found at #{raw_url} --- "
      find_or_create( product, 'GPL-2.0', raw_url, version )
      return 'GPL-2.0'
    end

    if is_agpl_30?( content )
      logger.info " -- AGPL-3.0 found at #{raw_url} --- "
      find_or_create( product, 'AGPL-3.0', raw_url, version )
      return 'AGPL-3.0'
    end

    if is_lgpl_30?( content )
      logger.info " -- LGPL-3.0 found at #{raw_url} --- "
      find_or_create( product, 'LGPL-3.0', raw_url, version )
      return 'LGPL-3.0'
    end

    if is_ruby?( content )
      logger.info " -- Ruby found at #{raw_url} --- "
      find_or_create( product, 'Ruby', raw_url, version )
      return 'Ruby'
    end

    if is_php_301?( content )
      logger.info " -- PHP License 3.01 found at #{raw_url} --- "
      find_or_create( product, 'PHP-3.01', raw_url, version )
      return 'PHP-3.01'
    end

    if is_mit?( content ) || is_mit_ol?( content )
      logger.info " -- MIT found at #{raw_url} --- "
      find_or_create( product, 'MIT', raw_url, version )
      return 'MIT'
    end

    if is_unlicense?( content )
      logger.info " -- The Unlicense found at #{raw_url} --- "
      find_or_create( product, 'The Unlicense', raw_url, version )
      return 'The Unlicense'
    end

    if is_dwtfywt?( content )
      logger.info " -- DO WHAT THE FUCK YOU WANT found at #{raw_url} --- "
      find_or_create( product, 'DWTFYWTP License', raw_url, version )
      return 'DWTFYWTP License'
    end

    if is_apache_20?( content ) || is_apache_20_short?( content )
      logger.info " -- Apache License 2.0 found at #{raw_url} --- "
      find_or_create( product, 'Apache-2.0', raw_url, version )
      return 'Apache-2.0'
    end

    if is_mpl_20?( content ) || is_mpl_20_short?( content )
      logger.info " -- Mozilla Public License Version 2.0 found at #{raw_url} --- "
      find_or_create( product, 'MPL-2.0', raw_url, version )
      return 'MPL-2.0'
    end

    logger.info " ---- NOT RECOGNIZED at #{raw_url} ---- "
    nil
  rescue => e
    logger.error "ERROR in recognize_license for url: #{raw_url}"
    logger.error e.message
    logger.error e.backtrace.join("\n")
    nil
  end


  private


    def self.find_or_create product, name, url, version = nil
      License.find_or_create_by({:language => product.language, :prod_key => product.prod_key,
        :version => version, :name => name, :url => url, :source => A_SOURCE_G })
    end


    def self.fetch_product link
      product = link.product
      return product if product

      if link.language.eql?("Java")
        product = Product.fetch_product "Clojure", link.prod_key
      end
      ensure_language(link, product)

      if product.nil?
        logger.info "REMOVE link #{link.to_s} because no corresponding product found!"
        link.remove
      end

      product
    end


    def self.ensure_language link, product
      return true if product.nil?
      return true if product.language.eql?(link.language)

      link.language = product.language
      link.save
    rescue => e
      p e.message
      logger.info "DELETE #{link.to_s}"
      link.remove
      false
    end



    def self.is_widen_commercial_license? content
      return false if content.match(/Widen\s+Commercial\s+License\s+Agreement/i).nil?
      return false if content.match(/Widen\s+Enterprises/i).nil?
      return false if content.match(/Widen\s+hereby\s+grants/i).nil?
      return false if content.match(/from\s+Widen/i).nil?

      return true
    end



    def self.is_php_301? content
      return false if content.match(/The PHP License, version 3\.01/i).nil?
      return false if content.match(/Redistribution and use in source and binary forms/i).nil?
      return false if content.match(/with or without/i).nil?
      return false if content.match(/is permitted provided that the following conditions/i).nil?
      return false if content.match(/The name "PHP" must not be used to endorse or promote products/i).nil?
      return false if content.match(/written permission, please contact group@php.net/i).nil?

      return true
    end


    def self.is_mit? content
      return false if content.match(/Permission is hereby granted, free of charge, to any person obtaining/i).nil?
      return false if content.match(/a copy of this software and associated documentation files/i).nil?
      return false if content.match(/to deal in the Software without restriction, including without limitation the rights/i).nil?
      return false if content.match(/to use, copy, modify, merge, publish, distribute, sublicense, and/i).nil?
      return false if content.match(/or sell/i).nil?
      return false if content.match(/copies of the Software, and to permit persons to whom the Software is/i).nil?
      return false if content.match(/furnished to do so, subject to the following conditions/i).nil?

      return false if content.match(/THE SOFTWARE IS PROVIDED/i).nil?
      return false if content.match(/AS IS/i).nil?
      return false if content.match(/WITHOUT WARRANTY OF ANY KIND/i).nil?
      return false if content.match(/EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF/i).nil?
      return false if content.match(/MERCHANTABILITY, FITNESS FOR A PARTICULAR PURP/i).nil?
      return false if content.match(/LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION/i).nil?
      return false if content.match(/OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION/i).nil?
      return false if content.match(/WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE/i).nil?
      return false if content.match("BSD License")

      return true
    end

    def self.is_mit_ol? content
      return false if content.match(/is distributed under \[MIT license\]\(http\:\/\/mutedsolutions.mit-license.org\/\)/i).nil?
      return true
    end


    def self.is_unlicense? content
      return false if content.match(/This is free and unencumbered software released into the public domain/i).nil?
      return false if content.match(/Anyone is free to copy, modify, publish, use, compile, sell, or/i).nil?
      return false if content.match(/distribute this software, either in source code form or as a compiled/i).nil?
      return false if content.match(/binary, for any purpose, commercial or non-commercial, and by any means/i).nil?

      return false if content.match(/In jurisdictions that recognize copyright laws, the author or authors/i).nil?
      return false if content.match(/of this software dedicate any and all copyright interest in the/i).nil?
      return false if content.match(/software to the public domain. We make this dedication for the benefit/i).nil?
      return false if content.match(/of the public at large and to the detriment of our heirs and/i).nil?
      return false if content.match(/successors. We intend this dedication to be an overt act of/i).nil?
      return false if content.match(/relinquishment in perpetuity of all present and future rights to this/i).nil?
      return false if content.match(/software under copyright law/i).nil?

      return false if content.match(/THE SOFTWARE IS PROVIDED/i).nil?
      return false if content.match(/AS IS/i).nil?
      return false if content.match(/WITHOUT WARRANTY OF ANY KIND/i).nil?
      return false if content.match(/EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF/i).nil?
      return false if content.match(/MERCHANTABILITY, FITNESS FOR A PARTICULAR PURP/i).nil?
      return false if content.match(/LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION/i).nil?
      return false if content.match(/OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION/i).nil?
      return false if content.match(/WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE/i).nil?

      return true
    end


    def self.is_dwtfywt? content
      return false if content.match(/DO WHAT THE FUCK YOU WANT TO PUBLIC LICENSE/i).nil?
      return false if content.match(/TERMS AND CONDITIONS FOR COPYING, DISTRIBUTION AND MODIFICATION/i).nil?
      return false if content.match(/You just DO WHAT THE FUCK YOU WANT TO/i).nil?
      return true
    end


    def self.is_ruby? content
      return false if content.match(/place your modifications in the Public Domain or otherwise/i).nil?
      return false if content.match(/make them Freely Available, such as by posting said/i).nil?
      return false if content.match(/modifications to Usenet or an equivalent medium, or by allowing/i).nil?
      return false if content.match(/the author to include your modifications in the software/i).nil?

      return false if content.match(/use the modified software only within your corporation or organization/i).nil?

      return false if content.match(/rename any non-standard executables so the names do not conflict with standard executables, which must also be provided./i).nil?

      return false if content.match(/make other distribution arrangements with the author./i).nil?

      return false if content.match(/You may distribute the software in object code or executable/i).nil?
      return false if content.match(/form, provided that you do at least ONE of the following/i).nil?

      return false if content.match(/distribute the executables and library files of the software/i).nil?
      return false if content.match(/accompany the distribution with the machine-readable source of the software/i).nil?

      return false if content.match(/give non-standard executables non-standard names, with/i).nil?
      return false if content.match(/instructions on where to get the original software distribution/i).nil?
      return false if content.match(/make other distribution arrangements with the author/i).nil?

      return false if content.match(/You may modify and include the part of the software into any other software/i).nil?
      return false if content.match(/possibly commercial/i).nil?

      return false if content.match(/The scripts and library files supplied as input to or produced a/i).nil?
      return false if content.match(/output from the software do not automatically fall under the/i).nil?

      return false if content.match(/THIS SOFTWARE IS PROVIDED/i).nil?
      return false if content.match(/AS IS/i).nil?
      return false if content.match(/AND WITHOUT ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, WITHOUT LIMITATION, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE/i).nil?
      return true
    end


    def self.is_new_bsd? content
      return false if content.match(/Redistribution and use/i).nil?
      return false if content.match(/in source and binary forms, with or without modification, are permitted provided that the following conditions are met/i).nil?

      return false if content.match(/Redistributions of source code must retain the above copyright notice, this list of conditions and the following disclaimer/i).nil?

      return false if content.match(/Redistributions in binary form must reproduce the above copyright notice, this list of conditions and the following disclaimer in the documentation and/i).nil?
      return false if content.match(/or other materials provided with the distribution/i).nil?

      return false if content.match(/the names of .* contributors may be used to endorse or promote products derived from this software without specific prior written permission/i).nil? && content.match(/The name of the author may not be used to endorse or promote products derived from this software without specific prior written permission/i).nil?

      return false if content.match(/THIS SOFTWARE IS PROVIDED BY/i).nil?
      return false if content.match(/AS IS/i).nil?
      return false if content.match(/AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT/i).nil?
      return false if content.match(/LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR/i).nil?
      return false if content.match(/A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL/i).nil?
      return false if content.match(/BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES/i).nil?
      return false if content.match(/INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION/i).nil?
      return false if content.match(/HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT/i).nil?
      return false if content.match(/INCLUDING NEGLIGENCE OR OTHERWISE/i).nil?
      return false if content.match(/ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE/i).nil?
      return true
    end

    def self.is_BSD_2_clause? content
      return false if content.match(/Redistribution and use in source and binary forms, with or without modification, are permitted provided that the following conditions are met/i).nil?

      return false if content.match(/Redistributions of source code must retain the above copyright notice, this list of conditions and the following disclaimer/i).nil?

      return false if content.match(/Redistributions in binary form must reproduce the above copyright notice, this list of conditions and the following disclaimer in the documentation and/i).nil?
      return false if content.match(/or other materials provided with the distribution/i).nil?

      return false if content.match(/THIS SOFTWARE IS PROVIDED BY/i).nil?
      return false if content.match(/AS IS/i).nil?
      return false if content.match(/AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT/i).nil?
      return false if content.match(/LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR/i).nil?
      return false if content.match(/A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL/i).nil?
      return false if content.match(/BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES/i).nil?
      return false if content.match(/INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION/i).nil?
      return false if content.match(/HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT/i).nil?
      return false if content.match(/INCLUDING NEGLIGENCE OR OTHERWISE/i).nil?
      return false if content.match(/ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE/i).nil?
      return true
    end


    def self.is_apache_20? content
      return false if content.match(/Apache License Version,* 2.0/i).nil?
      return false if content.match(/TERMS AND CONDITIONS FOR USE, REPRODUCTION, AND DISTRIBUTION/i).nil?
      return false if content.match(/shall mean the terms and conditions for use, reproduction, and distribution as defined by Sections 1 through 9 of this document/i).nil?
      return true
    end

    def self.is_apache_20_short? content
      return false if content.match(/apache\.org\/licenses\/LICENSE-2\.0/i).nil?
      return false if content.match(/Licensed under the Apache License, Version 2.0/i).nil?
      return true
    end


    def self.is_mpl_20? content
      return false if content.match(/Mozilla Public License,* \w*\s*2.0/i).nil?
      return false if content.match(/Contributor/i).nil?
      return false if content.match(/means each individual or legal entity that creates, contributes to the creation of, or owns Covered Software/i).nil?
      return false if content.match(/means Covered Software of a particular Contributor/i).nil?
      return false if content.match(/Mozilla Foundation is the license steward. Except as provided in Section 10.3/i).nil?
      return false if content.match(/The licenses granted in this Section 2 are the only rights granted under this License/i).nil?
      return false if content.match(/under Patent Claims infringed by Covered Software in the absence of its Contributions/i).nil?
      return false if content.match(/This License does not grant any rights in the trademarks/i).nil?
      return false if content.match(/No Contributor makes additional grants as a result of Your choice to distribute the Covered Software under a subsequent version of this License/i).nil?
      return true
    end

    def self.is_mpl_20_short? content
      return false if content.match(/This Source Code Form is subject to the terms of the Mozilla Public/i).nil?
      return false if content.match(/License,* v. 2.0. If a copy of the MPL was not distributed with this/i).nil?
      return false if content.match(/file,* You can obtain one at/i).nil?
      return true
    end


    def self.is_gpl_20? content
      return false if content.match(/GNU GENERAL PUBLIC LICENSE,* Version 2/i).nil?
      return false if content.match(/the GNU General Public License is intended to guarantee your freedom to share and change free software/i).nil?
      return true
    end

    def self.is_gpl_30? content
      return false if content.match(/GNU GENERAL PUBLIC LICENSE,* Version 3/i).nil?
      return false if content.match(/The GNU General Public License is a free, copyleft license for/i).nil?
      return false if content.match(/"This License" refers to version 3 of the GNU General Public License/i).nil?
      return true
    end

    def self.is_gpl_30_short? content
      return false if content.match(/License: GNU General Public License,* version 3 \(GPL-3.0\)/i).nil?
      return false if content.match(/http\:\/\/www\.opensource\.org\/licenses\/gpl-3\.0\.html/i).nil?
      return false if content.match("BSD")
      return false if content.match("MIT")
      return false if content.match("Mozilla")
      return false if content.match("CCL")
      return true
    end


    def self.is_agpl_30? content
      return false if content.match(/AFFERO GENERAL PUBLIC LICENSE,* Version 3/i).nil?
      return false if content.match(/The GNU Affero General Public License is a free/i).nil?
      return false if content.match(/Affero General Public License is designed specifically to ensure that/i).nil?
      return false if content.match(/refers to version 3 of the GNU Affero General Public License/i).nil?
      return true
    end


    def self.is_lgpl_30? content
      return false if content.match(/GNU (LESSER|Library) General public license,* Version 3/i).nil?
      return false if content.match(/the GNU (LESSER|Library) General Public License incorporates the terms and conditions of version 3 of the/i).nil?
      return true
    end


    def self.prepare_content content
      content = content.force_encoding("UTF-8")
      content = content.gsub(/\u2028/, "")
      content = content.gsub(/\n/, " ")
      content = content.gsub(/\r/, " ")
      content = content.gsub("\xE2\x80\xA8", " ")
      content = content.gsub(/\s+, /, ", ")
      content = content.gsub(/\s+/, " ")

      content
    end

end
