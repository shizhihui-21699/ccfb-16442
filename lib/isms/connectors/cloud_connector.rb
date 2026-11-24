# frozen_string_literal: true

require_relative "base"

module ISMS
  module Connectors
    # 云平台适配器（AWS/Azure/阿里云 IAM 的抽象）：输出账号及其状态变更流水。
    # 引擎不相信"当前状态"快照，而是用完整事件流重建任意历史时刻的账号状态。
    class CloudConnector < Base
      def normalize
        records_of_type("account").map do |r|
          events = (r["status_events"] || []).map do |ev|
            Canonical::AccountStatusEvent.new(status: normalize_status(ev["status"]),
                                              at: Time.parse(ev["at"]))
          end
          Canonical::Account.new(
            account_id: "#{@source}:#{r['login']}",
            source_system: @source,
            login: r["login"],
            identity_hint: r["identity_hint"],
            status_events: events
          )
        end
      end

      private

      # 各云厂商术语统一：blocked/suspended/key_deleted 一律规范为 disabled
      def normalize_status(raw)
        %w[disabled blocked suspended deactivated key_deleted].include?(raw) ? "disabled" : raw
      end
    end
  end
end
