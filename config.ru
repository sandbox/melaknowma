require 'rubygems'

require 'sinatra/base'

module Rash
  class Application < Sinatra::Base
    get "/" do
      "hello"
    end
  end
end

run Rash::Application
