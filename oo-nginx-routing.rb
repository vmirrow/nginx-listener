#!/usr/bin/ruby


## Guide to writing a router that listens to the OpenShift ActiveMQ routing plugin
#  Step 1  : Listen to ActiveMQ topic 'routinginfo'.
#            Note that the ActiveMQ routing plugin has to be configured with the same creds (routinginfo/routinginfopasswd)
#            Also note that host/port are hardcoded in this script
#  Step 2  : The following events from OpenShift as the applications go through their life cycle
#            [:create_application, :delete_application, :add_gear, :delete_gear, :add/remove_ssl, :add/remove_alias]
#  Step 3  : With each action reload the routing table of the router
#            The arguments provided with all the actions are app_name, namespace, public_address, public_port.
#  Step 3a : Use 'protocols' field provided with add_gear to tailor the routing methods. Values could be tcp, http, ws, https, wss, <custom>
#  Step 3b : Use the 'types' field to identify the kind of endpoint. e.g. most will be web_framework, some maybe load_balancer.
#            Clearly, if the router plans to route to load_balancer ones, then the web_framework ones should be inactive.
#            Unless the situation is that all load_balancer endpoints are down.
#  Step 3c : Use the 'mappings' field to identify url routes. The non-root routes may require special treatment like source-ip verification,
#            no HA load balancing, ssl_cert etc.
#            Common use case will be admin consoles like phpmyadmin. (Details for this are yet to be sorted out.)
#  Step 4  : Look at the ssl_cert notifications for the application, and whether to configure the router accordingly for requests coming in
#  Step 5  : Finally look at alias notifications. All aliases will need to be accomodated at any time during the application's lifecycle.
#
#  Note : add_gear/delete_gear do not correspond to actual addition and removal of gear, but that of endpoints.
#  One gear added to OpenShift application may result in several endpoints being created, and they will all result in respective add_gear notifications at the router level.


##
# Sample routing listener for nginx (very plain, does not look at any protocols/aliases etc)
#           Look for add_gear/load_balancer message on the topic and add/edit nginx config file
#           Look for delete_gear/load_balancer message and edit the nginx config file
#           Look for delete_application message and remove the nginx config file
##

require 'rubygems'
require 'stomp'
require 'yaml'

CONF_DIR='/opt/rh/nginx16/root/etc/nginx/conf.d/'

def add_haproxy(appname, namespace, ip, port)
  scope = "#{appname}-#{namespace}"
  file = File.join(CONF_DIR, "#{scope}.conf")
  if File.exist?(file)
    `sed -i 's/upstream #{scope} {/&\\n      server #{ip}:#{port};/' #{file}`
  else
    # write a new one
    template = <<-EOF
    upstream #{scope} {
      least_conn;
      server #{ip}:#{port};
    }
    server {
      listen 8000;
      server_name ha-#{scope}.us.platform.dell.com;
      location / {
        proxy_pass http://#{scope};
      }
    }
    server {
      listen 8443 ssl;
      server_name ha-#{scope}.us.platform.dell.com;
      location / {
        proxy_pass http://#{scope};
      }
    }
EOF
    File.open(file, 'w') { |f| f.write(template) }
  end
  `service nginx16-nginx reload`
end


c = Stomp::Client.new("routinginfo", "P@ssw0rd", "broker1.us.platform.dell.com", 61613, true)
c.subscribe('/topic/routinginfo') { |msg|
  h = YAML.load(msg.body)
  puts "The message action is #{h[:action]}"
  if h[:action] == :add_gear
    if h[:types].include? "load_balancer"
       add_haproxy(h[:app_name], h[:namespace], h[:public_address], h[:public_port])
       puts "Added routing endpoint for #{h[:app_name]}-#{h[:namespace]}"
    end
  elsif h[:action] == :delete_gear
  elsif h[:action] == :delete_application
     scope = "#{h[:app_name]}-#{h[:namespace]}"
     puts "Application scope name is calculated as: #{scope}"
     file = File.join(CONF_DIR, "#{scope}.conf")
     if File.exist?(file)
       puts "File with name: #{file} detected, attempting removal"
       `rm -f #{file}`
       `service nginx16-nginx reload`
       puts "Removed configuration for #{scope}"
     else
       puts "File with name: #{file} not found"
     end
  end
}
c.join

