# frozen_string_literal: true

require "time"
require_relative "../support/time_range"

module ISMS
  module Domain
    # 例外窗口（难点2：控制的合理例外）。
    #
    # 例外不是"把发现抹掉"，而是一段带审批链和有效期的受控豁免：
    #   - 必须经过审批（approved 状态、审批人非申请人本人——职责分离 SoD）
    #   - 有明确有效期，过期自动失效，引擎随即恢复告警
    #   - 可声明补偿控制（compensating_controls），审核员据此评估残余风险
    #   - 通过 scope（控制ID + 资源引用）精确限定适用范围，不能跨控制滥用
    class ExceptionWindow
      attr_reader :exception_id, :control_id, :resource_ref, :start_time, :end_time,
                  :status, :requested_by, :approved_by, :reason,
                  :compensating_controls, :validation_errors

      def initialize(attrs)
        @exception_id = attrs[:exception_id]
        @control_id = attrs[:control_id]
        @resource_ref = attrs[:resource_ref] # 如 "account:aws::iam::zhangsan-key" 或 "mr:repo!42"
        @start_time = Time.parse(attrs[:start_time])
        @end_time = Time.parse(attrs[:end_time])
        @status = attrs[:status]
        @requested_by = attrs[:requested_by]
        @approved_by = attrs[:approved_by]
        @reason = attrs[:reason]
        @compensating_controls = attrs[:compensating_controls] || []
        @validation_errors = validate
      end

      def valid?
        @validation_errors.empty?
      end

      def applies_to?(control_id:, resource_ref:)
        @control_id == control_id && @resource_ref == resource_ref
      end

      def active_at?(time)
        valid? && time >= @start_time && time < @end_time
      end

      def range
        TimeRange.new(@start_time, @end_time)
      end

      # 与给定区间的交集（用于引擎在时间轴上切分豁免段）
      def overlap_with(time_range)
        range.intersection(time_range)
      end

      def to_h
        {
          "exception_id" => @exception_id,
          "control_id" => @control_id,
          "resource_ref" => @resource_ref,
          "valid_from" => @start_time.utc.iso8601,
          "valid_until" => @end_time.utc.iso8601,
          "status" => @status,
          "requested_by" => @requested_by,
          "approved_by" => @approved_by,
          "reason" => @reason,
          "compensating_controls" => @compensating_controls,
          "valid" => valid?,
          "validation_errors" => @validation_errors
        }
      end

      private

      def validate
        errors = []
        errors << "例外 #{@exception_id} 缺少审批（状态=#{@status}）" unless @status == "approved"
        if @requested_by && @approved_by && @requested_by == @approved_by
          errors << "例外 #{@exception_id} 违反职责分离：申请人与审批人为同一人（#{@requested_by}）"
        end
        errors << "例外 #{@exception_id} 有效期起点晚于终点" if @start_time >= @end_time
        errors << "例外 #{@exception_id} 未声明理由" if @reason.nil? || @reason.strip.empty?
        errors
      end
    end
  end
end
