require 'rubygems'
require 'bundler'
require 'open-uri'
Bundler.require

# Load configuration file with Sintra::Contrib helper (http://www.sinatrarb.com/contrib/)
config_file 'config.yml'
# Load some helper methods from helpers.rb
require './helpers.rb'

# To manage the web session coookies
use Rack::Session::Pool

# Resource called by the Tropo WebAPI URL setting
post '/index.json' do
  # Fetches the HTTP Body (the session) of the POST and parse it into a native Ruby Hash object
  v = Tropo::Generator.parse request.env["rack.input"].read

  # Fetching certain variables from the resulting Ruby Hash of the session details
  # into Sinatra/HTTP sessions; this can then be used in the subsequent calls to the
  # Sinatra application
  session[:from] = v[:session][:from]
  session[:network] = v[:session][:to][:network]
  session[:channel] = v[:session][:to][:channel]

  # Set up connections to eldercare.gov API
  session[:client] = Savon.client(settings.eldercare_gov_api["wsdl_url"])
  login_response = session[:client].request :login do
    soap.body = { asUsername: settings.eldercare_gov_api["username"], asPassword: settings.eldercare_gov_api["password"] }
  end
  session[:client_token] = login_response[:login_response][:login_result]

  # Create a Tropo::Generator object which is used to build the resulting JSON response
  t = Tropo::Generator.new
    # If there is Initial Text available, we know this is an IM/SMS/Twitter session and
    # not voice
    if v[:session][:initial_text]
      # Add an 'ask' WebAPI method to the JSON response with appropriate options
      t.ask :name => 'initial_text', :choices => { :value => "[ANY]"}
      # Set a session variable with the zip the user sent when they sent the IM/SMS/Twitter
      # Request
      session[:zip] = v[:session][:initial_text]
    else
      # If this is a voice session, then add a voice-oriented ask to the JSON response
      # with the appropriate options
      t.ask :name => 'zip', :bargein => true, :timeout => 60, :attempts => 2,
          :say => [{:event => "timeout", :value => "Sorry, I did not hear anything."},
                   {:event => "nomatch:1 nomatch:2", :value => "Oops, that wasn't a five-digit zip code."},
                   {:value => "To search for eldercare resources in your area, please enter or say your 5 digit zip code"}],
                    :choices => { :value => "[5 DIGITS]"}
    end

    # Add a 'hangup' to the JSON response and set which resource to go to if a Hangup event occurs on Tropo
    t.on :event => 'hangup', :next => '/hangup.json'
    # Add an 'on' to the JSON response and set which resource to go when the 'ask' is done executing
    t.on :event => 'continue', :next => '/process_zip.json'

  # Return the JSON response via HTTP to Tropo
  t.response
end

# The next step in the session is posted to this resource when the 'ask' is completed in 'index.json'
post '/process_zip.json' do
  # Fetch the HTTP Body (the session) of the POST and parse it into a native Ruby Hash object
  v = Tropo::Generator.parse request.env["rack.input"].read

  # Create a Tropo::Generator object which is used to build the resulting JSON response
  t = Tropo::Generator.new
    # If no intial text was captured, use the zip in response to the ask in the previous route
    session[:zip] = v[:result][:actions][:zip][:value].gsub(" ","") unless session[:zip]

    # Fetch JSON output for the eldercare.gov API
    begin
      # Get data from the eldercare.gov API
      zip_response = session[:client].request :search_by_zip do
        soap.body = { asZipCode: session[:zip], asToken: session[:client_token] }
      end
      session[:data] = zip_response.body[:search_by_zip_response][:search_by_zip_result][:diffgram][:zip_code_data][:table1]
    rescue => e
      # Add a 'say' to the JSON response
      t.say "It looks like something went wrong with our eldercare dot gov data source. Please try again later."
      t.hangup
    end

    if session[:data].size > 0
      session[:data] = session[:data][0..8] if session[:data].size > 9 # limit to 9 results
      # List the resources to the user in the form of a question. The selected opportunity will be handled in the next route.
      t.say "Here are #{session[:data].size} resources. Press the resource number you want more information about."
      items_say = []
      session[:data].each_with_index{|item,i| items_say << "Resource ##{i+1} #{item[:tab_name]} at #{item[:name]}"}
      # Add an 'ask' to the JSON response
      t.ask :name => 'selection', :bargein => true, :timeout => 60, :attempts => 1,
          :say => [{:event => "nomatch:1", :value => "That wasn't a one-digit resource number. Here are your choices: "},
                   {:value => items_say.join(",, ")}], :choices => { :value => "[1 DIGITS]"}
    else
      # Add a 'say' to the JSON response and hangip the call
      t.say "Sorry, but we did not find any eldercare resources found in that zip code."
      t.hangup
    end

    # Add an 'on' to the JSON reponse and set which resource to go to when the 'ask' is done executing
    t.on  :event => 'continue', :next => '/process_selection.json'
    # Add a 'hangup' to the JSON reponse and set which resource to go to if a Hangup event occurs on Tropo
    t.on  :event => 'hangup', :next => '/hangup.json'

  t.response
end

# The next step in the session is posted to this resource when the 'ask' is completed in 'process_zip.json'
post '/process_selection.json' do
  v = Tropo::Generator.parse request.env["rack.input"].read
  t = Tropo::Generator.new
    # If we have a valid response from the last ask, do this section
    if v[:result][:actions][:selection][:value]
      item = session[:data][v[:result][:actions][:selection][:value].to_i-1]
      session[:say_string] = construct_details_string(item)
      t.say session[:say_string]

      # Ask the user if they would like an SMS sent to them
      t.ask :name => 'send_sms', :bargein => true, :timeout => 60, :attempts => 1,
            :say => [{:event => "nomatch:1", :value => "That wasn't a valid answer. "},
                   {:value => "Would you like to have a text message sent to you with the resource information?
                               Press 1 or say 'yes' to get a text message; Press 2 or say 'no' to conclude this session."}],
            :choices => { :value => "true(1,yes), false(2,no)"}
    else
      t.say "No opportunity with that value. Please try again."
      t.hangup
    end

    t.on  :event => 'continue', :next => '/send_text_message.json'
    t.on  :event => 'hangup', :next => '/hangup.json'

  t.response
end

# The next step in the session is posted to this resource when the 'ask' is completed in 'process_selection.json'
post '/send_text_message.json' do
  # Fetch the HTTP Body (the session) of the POST and parse it into a native Ruby Hash object
  v = Tropo::Generator.parse request.env["rack.input"].read

  # Create a Tropo::Generator object which is used to build the resulting JSON response
  t = Tropo::Generator.new
    if v[:result][:actions][:number_to_text] # The caller provided a phone # to text message
      t.message({
        :to => v[:result][:actions][:number_to_text][:value],
        :network => "SMS",
        :say => {:value => session[:say_string]}})
      t.say "Message sent."
    else # We dont have a number, so either ask for it if they selected to send a text message, or send to goodbye.json
      if v[:result][:actions][:send_sms][:value] == "true"
        t.ask :name => 'number_to_text', :bargein => true, :timeout => 60, :required => false, :attempts => 2,
              :say => [{:event => "timeout", :value => "Sorry, I did not hear anything."},
                     {:event => "nomatch:1 nomatch:2", :value => "Oops, that wasn't a 10-digit number."},
                     {:value => "What 10-digit phone number would you like to send the information to?"}],
                      :choices => { :value => "[10 DIGITS]"}
        next_url = '/send_text_message.json'
      end # No need for an else, send them off to /goodbye.json
    end

    # Tell it to say goodbye if there is no next_url set above
    next_url = '/goodbye.json' if next_url.nil?
    # Add an 'on' to the JSON response and set which resource to go to when the 'ask' is done executing
    t.on  :event => 'continue', :next => next_url
    # Add a 'hangup' to the JSON response and set which resource to go to if a Hangup event occurs on Tropo
    t.on  :event => 'hangup', :next => '/hangup.json'

  # Return the JSON response via HTTP to Tropo
  t.response
end

# The next step in the session is posted to this resource when the 'ask' is completed in 'send_text_message.json'
post '/goodbye.json' do
  # Fetch the HTTP Body (the session) of the POST and parse it into a native Ruby Hash object
  v = Tropo::Generator.parse request.env["rack.input"].read

  # Create a Tropo::Generator object which is used to build the resulting JSON response
  t = Tropo::Generator.new
    if session[:channel] == "VOICE"
      t.say "That's all. This service provided by social health insights dot com, data by elder care dot gov. Have a nice day. Goodbye."
    else # For text users, we can give them a URL (most clients will make the links clickable)
      t.say "That's all. This service by http://SocialHealthInsights.com; data by http://eldercare.gov"
    end
    t.hangup

    # Add a 'hangup' to the JSON response and set which resource to go to if a Hangup event occurs on Tropo
    t.on  :event => 'hangup', :next => '/hangup.json'
  t.response
end

# The next step in the session is posted to this resource when any of the resources do a hangup
post '/hangup.json' do
  v = Tropo::Generator.parse request.env["rack.input"].read
  puts " Call complete (CDR received). Call duration: #{v[:result][:session_duration]} second(s)"
end
