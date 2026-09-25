# frozen_string_literal: true

require "json"
require "erb"
require "fileutils"
require "tessel"

require_relative "lookalike/version"

module Lookalike
  class Error < StandardError; end
  class Mismatch < Error
    attr_reader :name, :result, :expected_path, :actual_path, :diff_path

    def initialize(name, result:, expected_path: nil, actual_path: nil, diff_path: nil)
      @name = name
      @result = result
      @expected_path = expected_path
      @actual_path = actual_path
      @diff_path = diff_path
      super(format_message)
    end

    def format_message
      "Snapshot mismatch: #{@name}\n" \
        "  diff pixels : #{@result.diff_pixels}\n" \
        "  max delta   : #{@result.max_delta}\n" \
        "  diff bbox   : #{@result.bounding_box.inspect}\n" \
        "  expected    : #{@expected_path}\n" \
        "  actual      : #{@actual_path}\n" \
        "  diff        : #{@diff_path}"
    end
  end
  class Pending < Error; end

  class Result
    attr_reader :expected, :actual, :diff_pixels, :max_delta, :bounding_box, :diff_image, :mode

    def initialize(expected:, actual:, diff_pixels:, max_delta:, bounding_box:, diff_image:, mode:, matched:)
      @expected = expected
      @actual = actual
      @diff_pixels = diff_pixels
      @max_delta = max_delta
      @bounding_box = bounding_box
      @diff_image = diff_image
      @mode = mode
      @matched = matched
    end

    def match?
      @matched
    end

    def to_h
      { "match" => match?, "diff_pixels" => diff_pixels, "max_delta" => max_delta,
        "bounding_box" => bounding_box, "mode" => mode.to_s }
    end
  end

  class Config
    attr_accessor :snapshot_dir, :output_dir, :default_mode, :threshold, :max_diff_pixels
    attr_reader :variants

    def initialize
      @snapshot_dir = "test/snapshots"
      @output_dir = "tmp/lookalike"
      @default_mode = :perceptual
      @threshold = 0.1
      @max_diff_pixels = 0
      @variants = {}
    end

    def variant(name, **options)
      @variants[name.to_sym] = options
    end

    def options_for(name)
      @variants[name.to_sym] || {}
    end
  end

  module Input
    module_function

    def normalize(value)
      return value if value.is_a?(Tessel::Image)
      if value.respond_to?(:width) && value.respond_to?(:height) && value.respond_to?(:to_rgba_bytes)
        return Tessel::Image.from_rgba(value.width, value.height, value.to_rgba_bytes)
      end
      return Tessel.read(value) if value.respond_to?(:to_path) || value.is_a?(String)

      raise TypeError, "unsupported image input: #{value.class}"
    end
  end

  module Metrics
    module Channel
      module_function

      def compare(expected, actual, max_delta:, allowed_pixels:)
        diff = 0
        maximum = 0
        box = nil
        each_pixel(expected, actual) do |x, y, a, b|
          delta = a.zip(b).map { |left, right| (left - right).abs }.max
          next unless delta > max_delta

          diff += 1
          maximum = [maximum, delta].max
          box = expand_box(box, x, y)
        end
        [diff <= allowed_pixels, diff, maximum, box]
      end

      def each_pixel(expected, actual)
        expected_bytes = expected.bytes
        actual_bytes = actual.bytes
        (0...expected.width).each do |x|
          (0...expected.height).each do |y|
            offset = (y * expected.width + x) * 4
            yield x, y, expected_bytes.byteslice(offset, 4).bytes, actual_bytes.byteslice(offset, 4).bytes
          end
        end
      end
      def expand_box(box, x, y)
        return [x, y, 1, 1] unless box

        x0 = [box[0], x].min
        y0 = [box[1], y].min
        x1 = [box[0] + box[2] - 1, x].max
        y1 = [box[1] + box[3] - 1, y].max
        [x0, y0, x1 - x0 + 1, y1 - y0 + 1]
      end
      private_class_method :expand_box
    end

    module YIQ
      module_function

      def compare(expected, actual, threshold:, allowed_pixels:, ignore_antialiasing: false)
        diff = 0
        maximum = 0
        box = nil
        Channel.each_pixel(expected, actual) do |x, y, left, right|
          delta = distance(composite(left), composite(right))
          maximum = [maximum, (delta * 255).round].max
          next unless delta > threshold
          next if ignore_antialiasing && Antialiasing.detect?(expected, x, y, actual)

          diff += 1
          box = expand_box(box, x, y)
        end
        [diff <= allowed_pixels, diff, maximum, box]
      end

      def distance(left, right)
        yiq_left = [0.29889531 * left[0] + 0.58662247 * left[1] + 0.11448223 * left[2], 0.59597799 * left[0] - 0.27417610 * left[1] - 0.32180189 * left[2], 0.21147017 * left[0] - 0.52261711 * left[1] + 0.31114694 * left[2]]
        yiq_right = [0.29889531 * right[0] + 0.58662247 * right[1] + 0.11448223 * right[2], 0.59597799 * right[0] - 0.27417610 * right[1] - 0.32180189 * right[2], 0.21147017 * right[0] - 0.52261711 * right[1] + 0.31114694 * right[2]]
        Math.sqrt(0.5053 * (yiq_left[0] - yiq_right[0])**2 + 0.299 * (yiq_left[1] - yiq_right[1])**2 + 0.1957 * (yiq_left[2] - yiq_right[2])**2)
      end
      private_class_method :distance

      def composite(pixel)
        alpha = pixel[3] / 255.0
        pixel.first(3).map { |channel| (channel * alpha + 255 * (1 - alpha)) / 255.0 }
      end
      private_class_method :composite

      def expand_box(box, x, y)
        return [x, y, 1, 1] unless box

        x0 = [box[0], x].min
        y0 = [box[1], y].min
        x1 = [box[0] + box[2] - 1, x].max
        y1 = [box[1] + box[3] - 1, y].max
        [x0, y0, x1 - x0 + 1, y1 - y0 + 1]
      end
      private_class_method :expand_box
    end
  end

  module Antialiasing
    module_function

    def detect?(image, x, y, other)
      intermediate_edge?(image, x, y) && edge?(other, x, y) ||
        intermediate_edge?(other, x, y) && edge?(image, x, y)
    end

    def edge?(image, x, y)
      values = neighborhood(image, x, y)
      values.max - values.min > 0.1
    end

    def intermediate_edge?(image, x, y)
      values = neighborhood(image, x, y)
      center = luminance(image[x, y])
      values.max - values.min > 0.1 && center > values.min + 0.02 && center < values.max - 0.02
    end

    def neighborhood(image, x, y)
      (-1..1).flat_map do |dy|
        (-1..1).filter_map { |dx| pixel = image[x + dx, y + dy]; luminance(pixel) if pixel }
      end
    end

    def luminance(pixel)
      alpha = pixel[3] / 255.0
      rgb = pixel.first(3).map { |channel| (channel * alpha + 255 * (1 - alpha)) / 255.0 }
      0.29889531 * rgb[0] + 0.58662247 * rgb[1] + 0.11448223 * rgb[2]
    end
    private_class_method :edge?, :intermediate_edge?, :neighborhood, :luminance
  end

  module DiffRenderer
    module_function

    def render(expected, actual, mode: :channel, threshold: 0.1, max_delta: 0, ignore_antialiasing: false)
      result = ImageBuilder.new(expected.width, expected.height)
      (0...expected.height).each do |y|
        (0...expected.width).each do |x|
          left = expected[x, y]
          right = actual[x, y]
          different = if mode == :channel
            left.zip(right).map { |a, b| (a - b).abs }.max > max_delta
          else
            Metrics::YIQ.send(:distance, Metrics::YIQ.send(:composite, left), Metrics::YIQ.send(:composite, right)) > threshold
          end
          antialias = different && ignore_antialiasing && mode.to_sym == :perceptual && Antialiasing.detect?(expected, x, y, actual)
          result[x, y] = if antialias
            [255, 220, 0, 255]
          elsif different
            [255, left[1] / 2, 0, 255]
          else
            [left[0] / 3, left[1] / 3, left[2] / 3, 255]
          end
        end
      end
      result
    end

    class ImageBuilder < Tessel::Image; end
  end

  module_function

  def config
    @config ||= Config.new
  end

  def configure
    yield config
  end

  def compare(expected, actual, mode: config.default_mode, max_delta: 0, allowed_pixels: config.max_diff_pixels, max_diff_pixels: nil, threshold: config.threshold, ignore_antialiasing: false)
    mode = mode.to_sym
    raise ArgumentError, "unknown comparison mode: #{mode}" unless %i[channel perceptual].include?(mode)
    allowed_pixels = max_diff_pixels unless max_diff_pixels.nil?
    allowed_pixels = Integer(allowed_pixels)
    raise ArgumentError, "allowed pixels must not be negative" if allowed_pixels.negative?
    max_delta = Integer(max_delta)
    raise ArgumentError, "max delta must be between 0 and 255" unless max_delta.between?(0, 255)
    threshold = Float(threshold)
    raise ArgumentError, "threshold must not be negative" if threshold.negative?
    expected = Input.normalize(expected)
    actual = Input.normalize(actual)
    unless expected.width == actual.width && expected.height == actual.height
      width = [expected.width, actual.width].max
      height = [expected.height, actual.height].max
      padded_expected = Tessel::Image.new(width, height)
      padded_actual = Tessel::Image.new(width, height)
      padded_expected.blit(expected, 0, 0, blend: :copy)
      padded_actual.blit(actual, 0, 0, blend: :copy)
      overlap_width = [expected.width, actual.width].min
      overlap_height = [expected.height, actual.height].min
      shared_expected = expected.crop(0, 0, overlap_width, overlap_height)
      shared_actual = actual.crop(0, 0, overlap_width, overlap_height)
      _matched, diff, maximum, box = if mode == :channel
        Metrics::Channel.compare(shared_expected, shared_actual, max_delta: max_delta, allowed_pixels: allowed_pixels)
      else
        Metrics::YIQ.compare(shared_expected, shared_actual, threshold: threshold, allowed_pixels: allowed_pixels, ignore_antialiasing: ignore_antialiasing)
      end
      diff_image = DiffRenderer.render(padded_expected, padded_actual, mode: mode, threshold: threshold, max_delta: max_delta, ignore_antialiasing: ignore_antialiasing)
      dimension_box = nil
      dimension_diff = 0
      (0...height).each do |y|
        (0...width).each do |x|
          next if x < expected.width && y < expected.height && x < actual.width && y < actual.height

          dimension_diff += 1
          diff_image[x, y] = [255, 0, 0, 255]
          if dimension_box
            x0 = [dimension_box[0], x].min
            y0 = [dimension_box[1], y].min
            x1 = [dimension_box[0] + dimension_box[2] - 1, x].max
            y1 = [dimension_box[1] + dimension_box[3] - 1, y].max
            dimension_box = [x0, y0, x1 - x0 + 1, y1 - y0 + 1]
          else
            dimension_box = [x, y, 1, 1]
          end
        end
      end
      if dimension_diff.positive?
        diff += dimension_diff
        maximum = [maximum, 255].max
        if box
          x0 = [box[0], dimension_box[0]].min
          y0 = [box[1], dimension_box[1]].min
          x1 = [box[0] + box[2] - 1, dimension_box[0] + dimension_box[2] - 1].max
          y1 = [box[1] + box[3] - 1, dimension_box[1] + dimension_box[3] - 1].max
          box = [x0, y0, x1 - x0 + 1, y1 - y0 + 1]
        else
          box = dimension_box
        end
      end
      return Result.new(expected: expected, actual: actual, diff_pixels: diff, max_delta: maximum, bounding_box: box, diff_image: diff_image, mode: mode, matched: false)
    end
    return Result.new(expected: expected, actual: actual, diff_pixels: 0, max_delta: 0, bounding_box: nil, diff_image: nil, mode: mode, matched: true) if expected.bytes == actual.bytes

    matched, diff, maximum, box = if mode == :channel
      Metrics::Channel.compare(expected, actual, max_delta: max_delta, allowed_pixels: allowed_pixels)
    elsif mode.to_sym == :perceptual
      Metrics::YIQ.compare(expected, actual, threshold: threshold, allowed_pixels: allowed_pixels, ignore_antialiasing: ignore_antialiasing)
    else
      Metrics::YIQ.compare(expected, actual, threshold: threshold, allowed_pixels: allowed_pixels, ignore_antialiasing: ignore_antialiasing)
    end
    Result.new(expected: expected, actual: actual, diff_pixels: diff, max_delta: maximum, bounding_box: box, diff_image: DiffRenderer.render(expected, actual, mode: mode, threshold: threshold, max_delta: max_delta, ignore_antialiasing: ignore_antialiasing), mode: mode, matched: matched)
  end

  def assert_snapshot(actual, name, **options)
    actual = Input.normalize(actual)
    variant = options.delete(:variant)
    variant_options = config.options_for(variant || :default)
    options = variant_options.merge(options)
    store = Store.new(config)
    expected_path = store.path(name, variant: variant)
    actual_path = store.output_path(name, "actual", variant: variant)
    diff_path = store.output_path(name, "diff", variant: variant)
    FileUtils.mkdir_p(File.dirname(actual_path))
    actual.write(actual_path)
    unless File.file?(expected_path)
      if update?(name)
        FileUtils.mkdir_p(File.dirname(expected_path))
        actual.write(expected_path)
        result = compare(actual, actual, **options)
        record_result(name, result, status: "updated", variant: variant, expected_path: expected_path, actual_path: actual_path)
        return result
      end
      unless ENV.key?("CI")
        FileUtils.mkdir_p(File.dirname(expected_path))
        actual.write(expected_path)
        record_result(name, compare(actual, actual, **options), status: "pending", variant: variant, expected_path: expected_path, actual_path: actual_path)
        raise Pending, "created new snapshot: #{expected_path}"
      end

      result = compare(actual, Tessel::Image.new(actual.width, actual.height))
      record_result(name, result, status: "failed", variant: variant, expected_path: expected_path, actual_path: actual_path, diff_path: diff_path)
      raise Mismatch.new(name, result: result, expected_path: expected_path, actual_path: actual_path, diff_path: diff_path)
    end

    result = compare(expected_path, actual, **options)
    if result.match?
      record_result(name, result, status: "passed", variant: variant, expected_path: expected_path, actual_path: actual_path)
      return result
    end
    result.diff_image&.write(diff_path)
    if update?(name)
      actual.write(expected_path)
      record_result(name, result, status: "updated", variant: variant, expected_path: expected_path, actual_path: actual_path, diff_path: diff_path)
      return compare(actual, actual, **options)
    end
    FileUtils.cp(expected_path, store.output_path(name, "expected", variant: variant))
    record_result(name, result, status: "failed", variant: variant, expected_path: expected_path, actual_path: actual_path, diff_path: diff_path)
    raise Mismatch.new(name, result: result, expected_path: expected_path, actual_path: actual_path, diff_path: diff_path)
  end

  def record_result(name, result, status:, variant: nil, expected_path:, actual_path:, diff_path: nil)
    relative = Store.new(config).send(:safe_name, name).tr("/", "__")
    relative = "#{relative}@#{variant}" if variant
    directory = File.join(config.output_dir, "results")
    FileUtils.mkdir_p(directory)
    payload = result.to_h.merge("name" => name.to_s, "variant" => variant&.to_s, "status" => status,
                               "expected" => expected_path, "actual" => actual_path, "diff" => diff_path)
    File.write(File.join(directory, "#{relative}.json"), JSON.generate(payload))
  end
  private_class_method :record_result

  def update?(name)
    value = ENV["LOOKALIKE_UPDATE"]
    return false unless value
    return true if value == "1" || value == "true"

    value.split(",").any? { |pattern| File.fnmatch?(pattern, name) }
  end
  private_class_method :update?

  class Store
    def initialize(config = Lookalike.config)
      @config = config
    end

    def path(name, variant: nil)
      relative = safe_name(name)
      candidate = variant ? File.join(@config.snapshot_dir, "#{relative}@#{safe_variant(variant)}.png") : nil
      candidate && File.file?(candidate) ? candidate : File.join(@config.snapshot_dir, "#{relative}.png")
    end

    def output_path(name, suffix, variant: nil)
      raise ArgumentError, "invalid output suffix" unless %w[actual expected diff].include?(suffix)
      File.join(@config.output_dir, "#{safe_name(name)}#{variant ? "@#{safe_variant(variant)}" : ""}.#{suffix}.png")
    end

    private

    def safe_name(name)
      name = String(name)
      raise ArgumentError, "snapshot name must be relative" if name.empty? || name.start_with?("/", "\\") || name.include?("\\") || name.include?("\0") || name.split("/").include?("..") || name.match?(/\A[A-Za-z]:/)

      name
    end

    def safe_variant(variant)
      value = variant.to_s
      raise ArgumentError, "invalid snapshot variant" unless value.match?(/\A[a-zA-Z0-9_-]+\z/)
      value
    end
  end

  module Assertions
    def assert_snapshot(actual, name, **options)
      Lookalike.assert_snapshot(actual, name, **options)
    rescue Pending => e
      if respond_to?(:pend)
        pend(e.message)
      elsif respond_to?(:skip)
        skip(e.message)
      else
        raise
      end
    rescue Mismatch => e
      respond_to?(:flunk) ? flunk(e.message) : raise
    end
  end

  module TestUnit
    def assert_snapshot(actual, name, **options)
      super
    rescue Pending => e
      pend(e.message)
    rescue Mismatch => e
      flunk(e.message)
    end
  end

  module Minitest
    def assert_snapshot(actual, name, **options)
      super
    rescue Pending => e
      skip(e.message)
    rescue Mismatch => e
      flunk(e.message)
    end
  end

  class Report
    def initialize(output_dir = Lookalike.config.output_dir)
      @output_dir = output_dir
    end

    def write(entries = Dir[File.join(@output_dir, "**", "*.actual.png")])
      path = File.join(@output_dir, "index.html")
      FileUtils.mkdir_p(@output_dir)
      body = entries.map do |actual|
        base = actual.delete_suffix(".actual.png")
        expected = "#{base}.expected.png"
        diff = "#{base}.diff.png"
        relative = ->(file) { ERB::Util.html_escape(file.delete_prefix("#{@output_dir}/")) }
        "<section><h2>#{ERB::Util.html_escape(File.basename(base))}</h2>" \
          "<div class='compare'><img src='#{relative.call(expected)}' alt='expected'>" \
          "<img class='actual' src='#{relative.call(actual)}' alt='actual'></div>" \
          "<input type='range' min='0' max='100' value='50' aria-label='actual image coverage'>" \
          "<img src='#{relative.call(diff)}' alt='difference'></section>"
      end.join
      File.write(path, "<!doctype html><meta charset='utf-8'><title>Lookalike</title>" \
        "<style>body{font:14px sans-serif;background:#171923;color:#eee}section{margin:2rem 0}.compare{position:relative;display:inline-block}.compare img{display:block;max-width:100%}.compare .actual{position:absolute;inset:0;clip-path:inset(0 50% 0 0)}</style>" \
        "#{body}<script>document.querySelectorAll('section').forEach(s=>{const range=s.querySelector('input');range.oninput=()=>s.querySelector('.actual').style.clipPath=`inset(0 ${100-range.value}% 0 0)`;});</script>")
      results = Dir[File.join(@output_dir, "results", "*.json")].filter_map do |file|
        JSON.parse(File.read(file))
      rescue JSON::ParserError
        nil
      end
      File.write(File.join(@output_dir, "results.json"), JSON.generate(results))
      path
    end
  end
end
