# frozen_string_literal: true

require "time"

module ISMS
  module Canonical
    # 原始记录：各系统拉回的数据原样落盘，绝不丢弃。证据包通过 raw_id 回溯到它。
    # observed_at  = 事实在源系统中的生效时间（业务时间）
    # collected_at = 本平台实际拉取到该数据的时间（系统时间）——双时态的两个轴
    RawRecord = Struct.new(:raw_id, :source, :entity_type, :external_id,
                           :payload, :observed_at, :collected_at, keyword_init: true)

    # 人员（来自人事系统，person_id 全局主键，用工号）
    Person = Struct.new(:person_id, :name, :email, :status, :termination_at, keyword_init: true) do
      def terminated?
        status == "terminated"
      end
    end

    # 账号（来自云平台 / 代码仓库等）。status_events 是账号状态变更流水，
    # 引擎据此重建账号在整个审核周期内的活跃区间。
    AccountStatusEvent = Struct.new(:status, :at, keyword_init: true)
    Account = Struct.new(:account_id, :source_system, :login, :identity_hint,
                         :status_events, :person_id, keyword_init: true) do
      def active_at?(time)
        current = "unknown"
        status_events.sort_by(&:at).each do |ev|
          break if ev.at > time

          current = ev.status
        end
        current == "active"
      end
    end

    # 代码合并请求。approvals 必须是 merge 之前由非作者本人做出的批准才算数。
    Approval = Struct.new(:reviewer_id, :at, keyword_init: true)
    MergeRequest = Struct.new(:mr_id, :repo, :author_id, :target_branch, :protected,
                              :state, :created_at, :merged_at, :approvals,
                              :exception_ticket_ids, keyword_init: true) do
      def merged?
        state == "merged" && !merged_at.nil?
      end
    end

    # 服务器补丁。deadline_at 由 SLA（按严重级别）算出；
    # installed_at 为 nil 表示截至采集时仍未安装。
    ServerPatch = Struct.new(:server_id, :hostname, :patch_id, :severity,
                             :released_at, :deadline_at, :installed_at, keyword_init: true) do
      def overdue_at?(time)
        time >= deadline_at && (installed_at.nil? || installed_at > time)
      end
    end

    # 工单（例外审批、紧急变更等）
    Ticket = Struct.new(:ticket_id, :type, :resource_ref, :status,
                        :created_at, :closed_at, keyword_init: true)
  end
end
