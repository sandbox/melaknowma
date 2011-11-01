$:.unshift(".")
require 'bundler'
Bundler.setup
require 'melaknowma'

Melaknowma::Application.configure do
  if ENV["REDISTOGO_URL"]
    uri = URI.parse(ENV["REDISTOGO_URL"])
    REDIS = Redis.new(:host => uri.host, :port => uri.port, :password => uri.password, :thread_safe => true)
  else
    REDIS = Redis.new(:host => "localhost", :port => 6379, :thread_safe => true)
  end

  Redis::Objects.redis = REDIS
  RedisSupport.redis = REDIS

  CrowdFlower.connect!(ENV["CROWDFLOWER_API_KEY"])

  AWS::S3::Base.establish_connection!(
    :access_key_id     => ENV['S3_ACCESS_KEY_ID'],
    :secret_access_key => ENV['S3_SECRET_ACCESS_KEY']
    )

  Melaknowma::Image::S3_BUCKET = ENV['S3_BUCKET']
end

run Melaknowma::Application
