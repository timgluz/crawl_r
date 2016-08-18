class FiregentoCrawler < SatisCrawler

  def logger
    if !defined?(@@log) || @@log.nil?
      @@log = Versioneye::DynLog.new("log/firegento.log", 10).log
    end
    @@log
  end

  A_BASE_URL  = 'http://packages.firegento.com'
  A_LINK_NAME = 'Firegento Page'


  def self.crawl packages = nil, early_exit = false
    crawler = FiregentoCrawler.new A_BASE_URL, A_LINK_NAME
    crawler.crawl packages, early_exit
  end


end
