class BowerCrawlWorker < Worker


  def work
    connection = get_connection
    connection.start
    channel = connection.create_channel
    channel.prefetch(1)
    queue   = channel.queue("bower_crawl", :durable => true)

    multi_log " [*] BowerCrawlWorker waiting for messages in #{queue.name}. To exit press CTRL+C"

    begin
      queue.subscribe(:ack => true, :block => true) do |delivery_info, properties, message|
        multi_log " [x] BowerCrawlWorker received #{message}"
        process_work message
        channel.ack(delivery_info.delivery_tag)
        multi_log " [x] BowerCrawlWorker job done #{message}"
      end
    rescue => e
      log.error e.message
      log.error e.backtrace.join("\n")
      connection.close
    end
  end


  def process_work package_name
    return nil if package_name.to_s.empty?

    user = user_with_gh_token
    token = user.github_token

    if package_name.eql?('::bower::')
      BowerStarter.crawl(token, 'https://bower.herokuapp.com/packages', true )
    else
      sps  = package_name.split("::")
      name = sps[0]
      url  = sps[1]
      BowerStarter.register_package name, url, token
    end
  rescue => e
    log.error e.message
    log.error e.backtrace.join("\n")
  end


end
