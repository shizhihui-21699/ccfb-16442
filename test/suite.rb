# frozen_string_literal: true

# 测试入口：ruby test/suite.rb
Dir.glob(File.expand_path("*_test.rb", __dir__)).sort.each { |f| require f }
