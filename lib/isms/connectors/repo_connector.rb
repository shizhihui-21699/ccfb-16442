# frozen_string_literal: true

require_relative "base"

module ISMS
  module Connectors
    # 代码仓库适配器（GitLab/GitHub/Gitea 的抽象）：
    # 同时输出账号流水（用于离职控制）与合并请求（用于评审控制）。
    class RepoConnector < Base
      def normalize
        accounts + merge_requests
      end

      def accounts
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

      def merge_requests
        records_of_type("merge_request").map do |r|
          approvals = (r["approvals"] || []).map do |a|
            Canonical::Approval.new(reviewer_id: a["reviewer_id"], at: Time.parse(a["at"]))
          end
          Canonical::MergeRequest.new(
            mr_id: r["id"],
            repo: r["repo"],
            author_id: r["author_id"],
            target_branch: r["target_branch"],
            protected: r["protected_branch"],
            state: r["state"],
            created_at: Time.parse(r["created_at"]),
            merged_at: r["merged_at"] && Time.parse(r["merged_at"]),
            approvals: approvals,
            exception_ticket_ids: r["exception_ticket_ids"] || []
          )
        end
      end

      private

      # GitLab 的 blocked / Bitbucket 的 suspended 等统一规范为 disabled
      def normalize_status(raw)
        %w[disabled blocked suspended deactivated].include?(raw) ? "disabled" : raw
      end
    end
  end
end
