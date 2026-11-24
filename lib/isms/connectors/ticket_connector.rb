# frozen_string_literal: true

require_relative "base"

module ISMS
  module Connectors
    # 工单系统适配器（Jira/ServiceNow/自研工单的抽象）：
    # 例外窗口的审批链、紧急变更单都从这里取证。
    class TicketConnector < Base
      def normalize
        records_of_type("ticket").map do |r|
          Canonical::Ticket.new(
            ticket_id: r["id"],
            type: r["type"],
            resource_ref: r["resource_ref"],
            status: r["status"],
            created_at: Time.parse(r["created_at"]),
            closed_at: r["closed_at"] && Time.parse(r["closed_at"])
          )
        end
      end
    end
  end
end
