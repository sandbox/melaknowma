Let's make some rash decisions

deploy it to heroku

Test A webhook

```
HTTParty.post("http://localhost:9292/crowdflower",
 {:body => {"signal" => "unit_complete", "payload" => {
 "data" => { "image_id" => "0675ce2264ddc3287ee14bae31a04fff06866ab7" },
 "job_id" => 68024,
"results" => {

 "judgments" => [
 {
 "tainted" => "false",
 "data" => { "color" => "yes" }
 }
 ]
}
}}})

```
