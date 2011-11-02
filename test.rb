require 'csv'
require 'httparty'

CSV.open("moles.csv", :headers => true).readlines.each do |row|
  response = HTTParty.get(row["url"])
  HTTParty.post("http://localhost:9292/api/upload",
    { :body =>
      {
        "options" => { "disease_real" => row["disease_real"] },
        "data" => response.parsed_response
      } })
  break
end
