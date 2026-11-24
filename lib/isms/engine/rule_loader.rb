# frozen_string_literal: true

require "yaml"

module ISMS
  module Engine
    # 规则即代码的声明式加载。每条规则带 version：
    # 评估结果会固化规则版本号，审核员可复现当时的判定逻辑。
    class RuleLoader
      def self.load_dir(dir)
        Dir.glob(File.join(dir, "*.yml")).sort.each_with_object({}) do |path, acc|
          rule = YAML.safe_load(File.read(path), permitted_classes: [Symbol])
          acc[rule["id"]] = rule
        end
      end
    end
  end
end
