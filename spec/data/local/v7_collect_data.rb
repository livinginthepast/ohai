
require File.expand_path(File.dirname(__FILE__) + '/../../spec_helper.rb')
require File.expand_path("#{File.dirname(__FILE__)}/v6_run_order.rb")

if __FILE__ == $0
  str = StringIO.new(V6RunOrder::RunList)

  list = []
  while !str.eof?
    list << str.readline.chomp
  end

  o = Ohai::System.new
  lo = Ohai::Loader.new(o)
  o.load_plugins
  
  list = lo.run_list
  list.each do |plugin|
    plugin.new(o).safe_run
  end

  o.data = o.data.sort_by { |key, value| key.to_s }
  puts o.json_pretty_print
end

