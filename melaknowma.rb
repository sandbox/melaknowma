require 'sinatra/base'
require 'resque'
require 'redis_support'
require 'redis/objects'
require 'crowdflower/message_service'
require 'haml'
require 'json'
require 'aws/s3'
require 'digest/sha1'

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

    def self.store(image_file)
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
    def self.process(crowdflower_data)
      crowdflower_results = crowdflower_data["results"] # { cf_field => { agg => result } }
    end
  end

  class Application < Sinatra::Base
    set :public_folder, File.join(ROOT, "public")
    set :views, File.join(ROOT, "views")

    get "/" do
      haml :index
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

      # Crowd.push(image)
      status(200)
    end

    post "/upload" do
      p params

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
