# frozen_string_literal: true

require_relative "base"

module ISMS
  module Connectors
    # 云平台补丁清单适配器（SSM/补丁管理器/漏洞扫描平台的抽象）。
    # SLA 截止时间由控制规则参数按严重级别统一计算，避免各系统口径不一致。
    class PatchConnector < Base
      # severity_sla_hours: { "critical" => 168, "high" => 360, ... }
      def initialize(severity_sla_hours:, **kwargs)
        super(**kwargs)
        @sla = severity_sla_hours
      end

      def normalize
        records_of_type("patch").map do |r|
          released = Time.parse(r["released_at"])
          Canonical::ServerPatch.new(
            server_id: r["server_id"],
            hostname: r["hostname"],
            patch_id: r["patch_id"],
            severity: r["severity"],
            released_at: released,
            deadline_at: released + (@sla[r["severity"]] || @sla["default"]) * 3600,
            installed_at: r["installed_at"] && Time.parse(r["installed_at"])
          )
        end
      end
    end
  end
end
