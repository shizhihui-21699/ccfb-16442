# frozen_string_literal: true

require "time"

module ISMS
  # 半开时间区间 [start_time, end_time)。整个引擎的时间轴运算都基于此值对象。
  # 半开语义保证相邻区间拼接时不会重复计算边界时刻。
  class TimeRange
    attr_reader :start_time, :end_time

    def initialize(start_time, end_time)
      raise ArgumentError, "时间区间起点不能晚于终点: #{start_time} > #{end_time}" if start_time > end_time

      @start_time = start_time
      @end_time = end_time
    end

    def empty?
      @start_time == @end_time
    end

    def duration_seconds
      @end_time - @start_time
    end

    def contains?(time)
      time >= @start_time && time < @end_time
    end

    def overlap?(other)
      @start_time < other.end_time && other.start_time < @end_time
    end

    # 交集；无交集时返回 nil
    def intersection(other)
      s = [@start_time, other.start_time].max
      e = [@end_time, other.end_time].min
      return nil if s >= e

      TimeRange.new(s, e)
    end

    # 从本区间中扣除若干区间，返回剩余区间数组（保持时间顺序、互不重叠）
    def subtract(others)
      others = others.reject { |o| !o.overlap?(self) }
      return [self] if others.empty?

      pieces = []
      cursor = @start_time
      others.sort_by(&:start_time).each do |o|
        cut_start = [o.start_time, @start_time].max
        cut_end = [o.end_time, @end_time].min
        next if cut_end <= cursor

        pieces << TimeRange.new(cursor, cut_start) if cut_start > cursor
        cursor = cut_end
        break if cursor >= @end_time
      end
      pieces << TimeRange.new(cursor, @end_time) if cursor < @end_time
      pieces.reject(&:empty?)
    end

    def to_h
      { "start" => iso(@start_time), "end" => iso(@end_time) }
    end

    def ==(other)
      other.is_a?(TimeRange) && start_time == other.start_time && end_time == other.end_time
    end
    alias eql? ==

    def hash
      [@start_time, @end_time].hash
    end

    private

    def iso(time)
      time.utc.iso8601
    end
  end
end
