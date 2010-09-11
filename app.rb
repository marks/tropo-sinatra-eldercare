%w(rubygems sinatra tropo-webapi-ruby open-uri json/pure helpers.rb).each{|lib| require lib}

use Rack::Session::Pool
# enable :sessions

post '/index.json' do
  v = Tropo::Generator.parse request.env["rack.input"].read
  session[:caller] = v[:session][:from][:id]
  session[:network] = v[:session][:network]
  session[:channel] = v[:session][:channel]
  t = Tropo::Generator.new(:voice => "kate")
    t.on :event => 'error', :next => '/error.json'     # For fatal programming errors. Log some details so we can fix it
    t.on :event => 'hangup', :next => '/hangup.json'   # When a user hangs or call is done. We will want to log some details.
    t.on :event => 'continue', :next => '/process_zip.json'
    t.ask :name => 'zip', :bargein => true, :timeout => 60, :required => true, :attempts => 4,
        :say => [{:event => "timeout", :value => "Sorry, I did not hear anything."},
                 {:event => "nomatch:1 nomatch:2 nomatch:3", :value => "That wasn't a five-digit zip code."},
                 {:value => "In what zip code would you like to search for volunteer opportunities in?."}],
                  :choices => { :value => "[5 DIGITS]"}
  t.response
end

post '/process_zip.json' do
  v = Tropo::Generator.parse request.env["rack.input"].read
  t = Tropo::Generator.new(:voice => "kate")
    t.on  :event => 'error', :next => '/error.json'
    t.on  :event => 'hangup', :next => '/hangup.json'
    t.on  :event => 'continue', :next => '/process_selection.json'
  
    params = {
      :num => "9",
      :output => "json",
      :vol_loc => v[:result][:actions][:zip][:value].gsub(" ",""),
      :vol_startdate => Time.now.strftime("%Y-%m-%d"),
      :vol_enddate => (Time.now+604800).strftime("%Y-%m-%d")
      }
      
    url = "http://www.allforgood.org/api/volopps?key=tropo"
    params.each{|key,value| url << "&#{key}=#{value}"}
    
    begin
      session[:data] = JSON.parse(open(url).read)
    rescue
      t.say "It looks like something went wrong with our data source. Please try again later. Goodbye."
      t.hangup
    end
    
    if session[:data]["items"].size > 0
      t.say "Here are #{session[:data]["items"].size} opportunities. Press the opportunity number you want more information about."
      items_say = []
      session[:data]["items"].each_with_index{|item,i| items_say << "Opportunity ##{i+1}: #{item["title"]}"}
      t.ask :name => 'selection', :bargein => true, :timeout => 60, :required => true, :attempts => 2,
          :say => [{:event => "nomatch:1 nomatch:2 nomatch:3", :value => "That wasn't a one-digit opportunity number."},
                   {:value => items_say.join(" <break time='600ms'/>, ")}],
                    :choices => { :value => "[1 DIGITS]"}
    else
      t.say "No volunteer opportunities found in zip code. Please try calling back later. Goodbye."
    end
  t.response  
end

post '/process_selection.json' do
  v = Tropo::Generator.parse request.env["rack.input"].read
  puts v.inspect
  t = Tropo::Generator.new
    t.on  :event => 'error', :next => '/error.json'  
    t.on  :event => 'hangup', :next => '/hangup.json'
    if v[:result][:actions][:selection][:value]
      item = session[:data]["items"][v[:result][:actions][:selection][:value].to_i-1]
      t.say "Information about opportunity #{item["title"]} is as follows: "
      t.say "From #{Time.parse(item["startDate"]).strftime("%a %m/%d at %I:%M %p")} to #{Time.parse(item["endDate"]).strftime("%a %m/%d at %I:%M %p")}" unless item["startDate"].empty? or item["endDate"].empty
      t.say "Contact "
      tinyurl = shorten_url(URI.unescape(item["xml_url"]))
      if session[:channel] == "VOICE"
        t.say "Official web page: #{readable_url(url)}. Again, #{readable_url(url)}"
      else
        t.say "Official web page: #{url}"
      end
      t.say "Description: #{item["description"]}"
      #  {
      #   "minAge": "", 
      #   "": "2010-10-06 19:30:00", 
      #   "contactPhone": "", 
      #   "sponsoringOrganizationName": "Greater DC Cares", 
      #   "contactName": "", 
      #   "addr1": "", 
      #   "street1": "", 
      #   "street2": "", 
      #   "contactEmail": "", 
      #   "url_short": "www.greaterdccares.org", 
      #  }, 
      
    else
      t.say "No opportunity with that value. Please try again."
    end
    t.hangup
  t.response
end

post '/hangup.json' do
  v = Tropo::Generator.parse request.env["rack.input"].read
  puts " Call complete. Call duration: #{v[:result][:call_duration]} second(s)"
  puts "  Caller info: ID=#{session[:caller][:id]}, Name=#{session[:caller][:name]}"
  puts "  Call logged in CDR. Tropo session ID: #{session[:id]}"
end

post '/error.json' do
  v = Tropo::Generator.parse request.env["rack.input"].read
  puts "!"*10 + "ERROR (see rack.input below); call ended"
  puts v.inspect
end