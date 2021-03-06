require "bundler/setup"
require "zk_recipes"

require "descriptive_statistics"
require "logger"
require "pry"
require "zk-server"

RSpec.configure do |config|
  # Enable flags like --only-failures and --next-failure
  config.example_status_persistence_file_path = ".rspec_status"

  config.expect_with :rspec do |c|
    c.syntax = :expect
  end

  config.before(:suite) do
    ZK_PORT = (27183..28_000).detect { |port| !system("nc -z localhost #{port}") }
    PROXY_PORT = (ZK_PORT + 1..28_000).detect { |port| !system("nc -z localhost #{port}") }

    ZK::Server.run do |c|
      c.client_port = ZK_PORT
      c.force_sync = false
      c.snap_count = 1_000_000
      c.max_session_timeout = 5_000 # ms
    end
  end

  config.after(:suite) do
    ZK::Server.shutdown
  end

  config.before(:each, zookeeper: true) do
    ZK.open("localhost:#{ZK_PORT}") do |zk|
      zk.rm_rf("/test")
      zk.mkdir_p("/test")
    end
  end

  config.before(:each, proxy: true) do |group|
    proxy_start(group.metadata[:throttle_bytes_per_sec])
  end

  config.after(:each, proxy: true) do
    proxy_stop
  end

  def proxy_start(throttle_bytes_per_sec = nil)
    limit = "-L #{throttle_bytes_per_sec}" if throttle_bytes_per_sec
    spawn(%{socat -T 10 -d TCP-LISTEN:#{PROXY_PORT},fork,reuseaddr,linger=1 SYSTEM:'pv -q #{limit} - | socat - "TCP:localhost:#{ZK_PORT}"'})
  end

  def proxy_stop
    system("lsof -i TCP:#{PROXY_PORT} -t | grep -v #{Process.pid} | xargs kill -9")
  end

  def spawn(cmd)
    warn "+ #{cmd}" if ENV["ZK_RECIPES_DEBUG"]
    Kernel.spawn(cmd)
  end

  def system(cmd)
    warn "+ #{cmd}" if ENV["ZK_RECIPES_DEBUG"]
    Kernel.system(cmd)
  end

  def almost_there(retries = 100)
    yield
  rescue RSpec::Expectations::ExpectationNotMetError
    raise if retries < 1
    sleep 0.1
    retries -= 1
    retry
  end
end
