# frozen_string_literal: true

module ISMS
  module Domain
    # 身份映射解析（难点1：各系统数据口径对不上）。
    #
    # 不同系统对"同一个人"的标识不同：人事用工号、代码仓库用用户名、
    # 云平台用 ARN、工单里只留了邮箱。本类只依据**显式映射表**做确定性解析，
    # 置信度低于阈值的一律进人工裁决队列，绝不靠模糊匹配静默猜测——
    # 错误的身份映射会让离职账号漏报，是审计中的高风险错误。
    class IdentityMapper
      # mapping 记录形如：
      #   { source_system: "gitlab", external_login: "zhangsan",
      #     person_id: "E1001", confidence: 1.0, source: "it_asset_registry" }
      def initialize(mappings:, confidence_threshold: 0.8)
        @confidence_threshold = confidence_threshold
        @index = {}
        @mappings = mappings
        mappings.each do |m|
          # 兼容 YAML（字符串键）与 Ruby Hash（符号键）两种来源，边界统一为字符串
          m = m.each_with_object({}) { |(k, v), acc| acc[k.to_s] = v }
          @index[key(m["source_system"], m["external_login"])] = m
        end
        @pending_review = []
      end

      # 把一个规范化账号解析到全局 person_id。
      # 返回 [person_id 或 nil, 置信度]；无法可靠解析时记录到人工裁决队列。
      def resolve(source_system:, external_login:, hint: nil)
        m = @index[key(source_system, external_login)]
        if m.nil?
          enqueue(source_system, external_login, hint, "无映射记录")
          return [nil, 0.0]
        end
        if m["confidence"] < @confidence_threshold
          enqueue(source_system, external_login, hint,
                  "置信度 #{m['confidence']} 低于阈值 #{@confidence_threshold}（来源：#{m['source']}）")
          return [nil, m["confidence"]]
        end

        [m["person_id"], m["confidence"]]
      end

      def annotate!(accounts)
        accounts.each do |acct|
          pid, _conf = resolve(source_system: acct.source_system,
                               external_login: acct.login,
                               hint: acct.identity_hint)
          acct.person_id = pid
        end
      end

      attr_reader :pending_review

      private

      def key(system, login)
        "#{system}::#{login.to_s.downcase}"
      end

      def enqueue(system, login, hint, reason)
        @pending_review << {
          source_system: system,
          external_login: login,
          identity_hint: hint,
          reason: reason
        }
      end
    end
  end
end
