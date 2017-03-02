class NpmCrawlWorker < Worker


  def work
    connection = get_connection
    connection.start
    channel = connection.create_channel
    channel.prefetch(1)
    queue   = channel.queue("npm_crawl", :durable => true)

    multi_log " [*] NpmCrawlWorker waiting for messages in #{queue.name}. To exit press CTRL+C"

    begin
      queue.subscribe(:ack => true, :block => true) do |delivery_info, properties, message|
        multi_log " [x] NpmCrawlWorker received #{message}"
        process_work message
        channel.ack(delivery_info.delivery_tag)
        multi_log " [x] NpmCrawlWorker job done #{message}"
      end
    rescue => e
      log.error e.message
      log.error e.backtrace.join("\n")
      connection.close
    end
  end


  def process_work package_name
    return nil if package_name.to_s.empty?

    if package_name.eql?('::npm::')
      NpmCrawler.crawl
    elsif package_name.eql?('::crawl_scoped::')
      NpmCrawler.crawl_scoped
    else
      NpmCrawler.crawle_package package_name
    end
  rescue => e
    log.error e.message
    log.error e.backtrace.join("\n")
  end


end
