require 'csv'
require 'httparty'

CSV.open("moles.csv", :headers => true).readlines.each do |row|
  response = HTTParty.get(row["url"])
  HTTParty.post("http://evening-sunset-5050.heroku.com/api/upload",
    { :body =>
      {
        "options" => { "disease_real" => row["disease_real"] },
        "data" => response.parsed_response
      } })
end
