
require File.expand_path(File.dirname(__FILE__) + '/../../spec_helper.rb')


if __FILE__ == $0
  o = Ohai::System.new
  o.all_plugins

  o.data = o.data.sort_by { |key, value| key.to_s }
  puts o.json_pretty_print
end
