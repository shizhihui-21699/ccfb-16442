# frozen_string_literal: true

$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))
require "minitest/autorun"
require "time"
require "isms"

class TimeRangeTest < Minitest::Test
  def t(s)
    Time.parse(s)
  end

  def test_intersection
    a = ISMS::TimeRange.new(t("2026-01-01T00:00:00Z"), t("2026-01-10T00:00:00Z"))
    b = ISMS::TimeRange.new(t("2026-01-05T00:00:00Z"), t("2026-01-15T00:00:00Z"))
    assert_equal t("2026-01-05T00:00:00Z"), a.intersection(b).start_time
    assert_equal t("2026-01-10T00:00:00Z"), a.intersection(b).end_time
  end

  def test_no_intersection_returns_nil
    a = ISMS::TimeRange.new(t("2026-01-01T00:00:00Z"), t("2026-01-02T00:00:00Z"))
    b = ISMS::TimeRange.new(t("2026-01-02T00:00:00Z"), t("2026-01-03T00:00:00Z")) # 半开，端点相接不算重叠
    assert_nil a.intersection(b)
  end

  def test_subtract_splits_into_two_pieces
    outer = ISMS::TimeRange.new(t("2026-01-01T00:00:00Z"), t("2026-01-10T00:00:00Z"))
    hole = ISMS::TimeRange.new(t("2026-01-04T00:00:00Z"), t("2026-01-06T00:00:00Z"))
    pieces = outer.subtract([hole])
    assert_equal 2, pieces.size
    assert_equal [t("2026-01-01T00:00:00Z"), t("2026-01-06T00:00:00Z")],
                 pieces.map(&:start_time)
    assert_equal [t("2026-01-04T00:00:00Z"), t("2026-01-10T00:00:00Z")],
                 pieces.map(&:end_time)
  end

  def test_rejects_inverted_range
    assert_raises(ArgumentError) do
      ISMS::TimeRange.new(t("2026-01-10T00:00:00Z"), t("2026-01-01T00:00:00Z"))
    end
  end
end
