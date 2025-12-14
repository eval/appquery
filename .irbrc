puts "Loading #{__FILE__}"
# put overrides/additions in '_irbrc'

IRB.conf[:HISTORY_FILE] = "#{ENV["PROJECT_ROOT"]}/tmp/.irb_history"

# Custom IRB prompt showing database adapter
db_indicator = begin
  adapter = ActiveRecord::Base.connection.adapter_name.downcase
  "\e[33m[#{adapter}]\e[0m "
rescue ActiveRecord::ConnectionNotEstablished, NameError
  "\e[34m[no-db]\e[0m "
end

IRB.conf[:PROMPT][:APPQUERY] = {
  PROMPT_I: "#{db_indicator}appquery> ",
  PROMPT_S: "#{db_indicator}appquery%l ",
  PROMPT_C: "#{db_indicator}appquery* ",
  RETURN: "=> %s\n"
}
IRB.conf[:PROMPT_MODE] = :APPQUERY
