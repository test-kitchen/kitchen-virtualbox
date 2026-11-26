name "parallels-apache2"

run_list "apache2_smoke::default"
cookbook "apache2_smoke", path: "cookbooks/apache2_smoke"
