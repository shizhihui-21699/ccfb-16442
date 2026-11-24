# frozen_string_literal: true

require "json"
require "time"
require_relative "../canonical/models"

module ISMS
  module Connectors
    # 连接器基类：负责把源系统 JSON 拉成 RawRecord（原样保留）并提供采集覆盖率。
    # 真实部署中各子类的 fetch 改为对 API/数据库的调用；normalize 逻辑保持不变，
    # 这样换接入方式不会影响评估引擎。
    class Base
      attr_reader :source, :expected_interval_hours, :collections

      def initialize(source:, data_path:, expected_interval_hours:)
        @source = source
        @data_path = data_path
        @expected_interval_hours = expected_interval_hours
        @file_data = JSON.parse(File.read(data_path))
        @collections = (@file_data["_collections"] || []).map do |c|
          { "at" => Time.parse(c["at"]), "status" => c["status"], "note" => c["note"] }
        end
      end

      # 原始记录落盘：payload 原样保留，证据包凭 raw_id 回溯
      def raw_records
        @raw_records ||= (@file_data["records"] || []).map do |r|
          Canonical::RawRecord.new(
            raw_id: "#{@source}:#{r['id']}",
            source: @source,
            entity_type: r["entity_type"],
            external_id: r["id"].to_s,
            payload: r,
            observed_at: Time.parse(r["observed_at"]),
            collected_at: Time.parse(r["collected_at"] || r["observed_at"])
          )
        end
      end

      # 两次成功采集的间隔超过预期，即构成数据缺口（难点3：缺口本身是审计发现）
      def coverage_gaps(period)
        successes = @collections.select { |c| c["status"] == "success" }
                                .map { |c| c["at"] }.sort
        gaps = []
        successes.each_cons(2) do |prev, nxt|
          gap_hours = (nxt - prev) / 3600.0
          next unless gap_hours > @expected_interval_hours

          # 只报告落在审核周期内的部分
          s = [prev, period.start_time].max
          e = [nxt, period.end_time].min
          next if s >= e

          gaps << {
            "range" => ISMS::TimeRange.new(s, e).to_h,
            "reason" => "采集间隔 #{gap_hours.round(1)} 小时，超过预期 #{@expected_interval_hours} 小时",
            "source" => @source
          }
        end
        gaps
      end

      def normalize
        raise NotImplementedError, "#{self.class} 必须实现 normalize"
      end

      protected

      def records_of_type(type)
        @file_data["records"].select { |r| r["entity_type"] == type }
      end
    end
  end
end
