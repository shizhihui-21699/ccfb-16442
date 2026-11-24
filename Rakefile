# frozen_string_literal: true

require "rake/testtask"

Rake::TestTask.new(:test) do |t|
  t.libs << "lib" << "test"
  t.test_files = FileList["test/**/*_test.rb"]
  t.warning = false
end

desc "运行端到端演示并在 output/ 生成证据包"
task :demo do
  ruby "demo/run_demo.rb"
end

task default: :test
