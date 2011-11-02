require 'sinatra/base'
require 'resque'
require 'redis_support'
require 'redis/objects'
require 'crowdflower/message_service'
require 'haml'
require 'json'
require 'aws/s3'
require 'digest/sha1'

module RedisSupport
  module ClassMethods
    def timeout_i(timeout)
      Time.now.to_i + timeout.to_i
    end
  end
end

# ASYM 67999
# BORDER 68000
# COLOR 68001
# DIAMETER
# ELEVATION 68002

module Melaknowma
  ROOT = File.expand_path(File.dirname(__FILE__))

  class Image
    S3_BUCKET = "configure_this"

    include RedisSupport
    redis_key :identifiers, "melaknowma:image"
    redis_key :identifier, "melaknowma:image:ID"

    attr_accessor :id, :image_file

    ATTRIBUTES = [ :symmetry, :border, :color, :diameter, :elevation, :diagnosis, :disease_real ]
    attr_accessor *ATTRIBUTES

    def self.list
      redis.smembers(Keys.identifiers)
    end

    def self.new_from_data(data, options = {})
      image = self.new
      image.image_file = StringIO.new(data)
      image.id = Digest::SHA1.hexdigest(data)
      image.diagnosis = "pending"
      ATTRIBUTES.each do |attr|
        if val = (options[attr] || options[attr.to_s])
          image.send("#{attr}=", val)
        end
      end
      image
    end

    def self.new_from_file(image_file, options = {})
      image = self.new
      image.image_file = image_file
      image.id = Digest::SHA1.hexdigest(image_file.path)
      image.diagnosis = "pending"
      ATTRIBUTES.each do |attr|
        if val = (options[attr] || options[attr.to_s])
          image.send("#{attr}=", val)
        end
      end
      image
    end

    def save
      if @image_file
        AWS::S3::S3Object.store(
          @id,
          @image_file.read,
          S3_BUCKET,
          :access => :public_read
          )
      end

      redis.sadd(Keys.identifiers, @id)
      ATTRIBUTES.each do |attr|
        next unless (val = self.send(attr))
        redis.hset(Keys.identifier(@id), attr, val)
      end

      self
    end

    def url
      "https://s3.amazonaws.com/#{S3_BUCKET}/#{@id}"
    end

    def self.progress(image_id)
      (redis.hgetall(Keys.identifier(image_id)).keys & Crowd::JOBS).size / Crowd::JOBS.size.to_f
    end

    def done?
      done = false
      self.class.redis_lock(self.id) do
        done = (redis.hgetall(Keys.identifier(self.id)).keys & Crowd::JOBS).size == Crowd::JOBS.size
      end
      return done
    end

    def self.get(identifier)
      if redis.sismember(Keys.identifiers, identifier)
        image = self.new
        image.id = identifier
        attributes = redis.hgetall(Keys.identifier(image.id))
        ATTRIBUTES.each do |attr|
          image.send("#{attr}=", attributes[attr.to_s])
        end
        image
      end
    end
  end

  class Crowd
    include RedisSupport
    redis_key :configuration, "crowd:configuration"

    JOBS = [ "symmetry", "border", "color" ] # , "diameter", "elevation" ]

    def self.configure(config)
      config.each do |key, value|
        redis.hset(Keys.configuration, key, value)
      end
    end

    def self.ensure_webhook
      config = configuration
      JOBS.each do |job|
        CrowdFlower.update_job(config[job], { "webhook_uri" => ENV["MELAKNOWMA_WEBHOOK"] }).send_now
      end
    end

    def self.configuration
      redis.hgetall(Keys.configuration)
    end

    def self.push(image)
      config = configuration
      JOBS.each do |job|
        CrowdFlower.upload_unit(config[job], { "image_id" => image.id, "url" => image.url }).send_now
      end
    end
  end

  class Doctor
    NO_WEIGHTS = {
      "color"    => 1,
      "border"   => 1,
      "symmetry" => 1
    }
    YES_WEIGHTS = {
      "color"    => 0,
      "border"   => 0,
      "symmetry" => 0
    }

    def self.process(crowdflower_data)
      # { cf_field => { agg => result } }
      image_id = crowdflower_data["data"]["image_id"]

      return unless image_id

      crowdflower_results = crowdflower_data["results"]

      crowdflower_field, junk = Crowd.configuration.find do |key, value|
        crowdflower_data["job_id"].to_i == value.to_i
      end

      field_score = crowdflower_results["judgments"].inject(0) do |score, judgment|
        if "false" == judgment["tainted"]
          score += ("no" == judgment["data"][crowdflower_field]) ? NO_WEIGHTS[crowdflower_field] : YES_WEIGHTS[crowdflower_field]
        else
          score
        end
      end

      judgments_count = crowdflower_results["judgments"].length

      image = Image.get(image_id)
      image.send("#{crowdflower_field}=", field_score)
      if image.done?
        diagnose(image)
      end
      image.save
    end

    def self.diagnose(image)
      # we should probably do something
      if image.color.to_i > 0 && image.border.to_i > 0 && image.symmetry.to_i > 0
        image.diagnosis = "get this checked by a doctor"
      else
        image.diagnosis = "likely benign"
      end
    end
  end

  class Application < Sinatra::Base
    set :public_folder, File.join(ROOT, "public")
    set :views, File.join(ROOT, "views")

    get "/" do
      haml :index
    end

    get "/list" do
      haml :list
    end

    get "/obscure_url_to_edit_job_settings" do
      haml :admin
    end

    get "/ensure_webhook" do
      Crowd.ensure_webhook
      redirect "/obscure_url_to_edit_job_settings"
    end

    post "/configurate" do
      Crowd.configure(params)
      redirect "/obscure_url_to_edit_job_settings"
    end

    get "/image/:id" do
      @image = Image.get(params[:id])
      haml :'image/show'
    end

    post "/api/upload" do
      image = Image.new_from_data(params["data"], params["options"])
      image.save

      Crowd.push(image)
      status(200)
    end

    post "/upload" do
      image = Image.new_from_file(params["image_mole"][:tempfile], params["image_mole"])
      image.save

      Crowd.push(image)
      redirect "/image/#{image.id}"
    end

    post "/crowdflower" do
      signal = params["signal"]
      return unless 'unit_complete' == signal

      if params['payload'].is_a?( String )
        payload = JSON.parse( params["payload"] )
      else
        payload = params['payload']
      end

      Doctor.process(payload)

      status(200)
    end
  end
end
