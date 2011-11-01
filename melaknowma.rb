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

    ATTRIBUTES = [ :symmetry, :border, :color, :diameter, :elevation, :diagnosis ]
    attr_accessor *ATTRIBUTES

    def self.new_from_file(image_file)
      image = self.new
      image.image_file = image_file
      image.id = Digest::SHA1.hexdigest(image_file.path)
      image
    end

    def save
      AWS::S3::S3Object.store(
        @id,
        @image_file.read,
        S3_BUCKET,
        :access => :public_read
        )

      redis.sadd(Keys.identifiers, @id)
      redis.hset(Keys.identifier(@id), :diagnosis, "pending")

      self
    end

    def url
      @id
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
      image = Image.new_from_file(image_file)
      image.save
    end
  end

  class Crowd
    def self.push(image_url)
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

    get "/image/:id" do
      @image = Image.get(params[:id])
      haml :'image/show'
    end

    post "/upload" do
      image = Image.store(params["image_mole"][:tempfile])
      Crowd.push(image.url)
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
