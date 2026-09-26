# frozen_string_literal: true

require "tmpdir"

RSpec.describe Lookalike do
  it "has a version number" do
    expect(Lookalike::VERSION).not_to be nil
  end

  it "compares channels and returns a bounding box" do
    expected = Tessel::Image.new(4, 4, fill: "#000000")
    actual = expected.dup
    actual[2, 1] = [255, 0, 0, 255]

    result = Lookalike.compare(expected, actual, mode: :channel)

    expect(result.match?).to be(false)
    expect(result.diff_pixels).to eq(1)
    expect(result.bounding_box).to eq([2, 1, 1, 1])
  end

  it "accepts image-like objects" do
    image = Tessel::Image.new(1, 1, fill: "#123456")
    object = Struct.new(:width, :height, :to_rgba_bytes).new(1, 1, image.bytes)

    expect(Lookalike.compare(image, object, mode: :channel).match?).to be(true)
  end

  it "validates comparison options even for equal or differently sized images" do
    image = Tessel::Image.new(1, 1)
    expect { Lookalike.compare(image, image, mode: :unknown) }.to raise_error(ArgumentError, /unknown comparison mode/)
    expect { Lookalike.compare(image, image, allowed_pixels: -1) }.to raise_error(ArgumentError, /allowed pixels/)
    result = Lookalike.compare(image, Tessel::Image.new(2, 1), mode: :channel)
    expect(result.diff_pixels).to eq(1)
    expect(result.bounding_box).to eq([1, 0, 1, 1])
    expect(result.diff_image.width).to eq(2)
    expect(result.diff_image.height).to eq(1)
  end

  it "rejects non-finite perceptual thresholds" do
    expected = Tessel::Image.new(1, 1, fill: "#000000")
    actual = Tessel::Image.new(1, 1, fill: "#ffffff")
    [Float::NAN, Float::INFINITY].each do |threshold|
      expect { Lookalike.compare(expected, actual, threshold: threshold) }.to raise_error(ArgumentError, /threshold/)
    end
  end

  it "counts each extra pixel once when image dimensions differ" do
    expected = Tessel::Image.new(1, 1, fill: "#ffffff")
    actual = Tessel::Image.new(2, 1, fill: "#ffffff")

    result = Lookalike.compare(expected, actual, mode: :channel)
    expect(result.match?).to be(false)
    expect(result.diff_pixels).to eq(1)
    expect(result.bounding_box).to eq([1, 0, 1, 1])

    transparent = Lookalike.compare(Tessel::Image.new(1, 1), Tessel::Image.new(2, 1), mode: :channel)
    expect(transparent.diff_image[1, 0]).to eq([255, 0, 0, 255])
  end

  it "rejects unsafe snapshot names" do
    expect { Lookalike::Store.new.path("../secret") }.to raise_error(ArgumentError)
    expect { Lookalike::Store.new.output_path("safe", "actual", variant: "../bad") }.to raise_error(ArgumentError)
  end

  it "keeps the real difference count when the allowance permits a match" do
    expected = Tessel::Image.new(2, 1)
    actual = expected.dup
    actual[1, 0] = [1, 0, 0, 0]
    result = Lookalike.compare(expected, actual, mode: :channel, allowed_pixels: 1)
    expect(result.match?).to be(true)
    expect(result.diff_pixels).to eq(1)
  end

  it "creates missing local snapshots and resolves variants" do
    Dir.mktmpdir do |dir|
      previous = Lookalike.config
      previous_ci = ENV.delete("CI")
      config = Lookalike::Config.new
      config.snapshot_dir = File.join(dir, "snapshots")
      config.output_dir = File.join(dir, "output")
      Lookalike.instance_variable_set(:@config, config)
      image = Tessel::Image.new(1, 1, fill: "#123456")
      expect { Lookalike.assert_snapshot(image, "nested/example") }.to raise_error(Lookalike::Pending)
      expect(config.snapshot_dir + "/nested/example.png").to satisfy { |path| File.file?(path) }
      expect(Lookalike.assert_snapshot(image, "nested/example").match?).to be(true)
      expect(Lookalike::Store.new.path("nested/example", variant: :metal)).to eq(config.snapshot_dir + "/nested/example.png")
      Lookalike::Report.new(config.output_dir).write
      expect(JSON.parse(File.read(File.join(config.output_dir, "results.json"))).map { |entry| entry["status"] }).to include("passed")
    ensure
      Lookalike.instance_variable_set(:@config, previous)
      ENV["CI"] = previous_ci if previous_ci
    end
  end

  it "keeps separate report results for nested and underscored snapshot names" do
    Dir.mktmpdir do |directory|
      previous = Lookalike.config
      previous_update = ENV["LOOKALIKE_UPDATE"]
      config = Lookalike::Config.new
      config.snapshot_dir = File.join(directory, "snapshots")
      config.output_dir = File.join(directory, "output")
      Lookalike.instance_variable_set(:@config, config)
      ENV["LOOKALIKE_UPDATE"] = "1"
      image = Tessel::Image.new(1, 1)
      %w[a/b a_b].each { |name| Lookalike.assert_snapshot(image, name) }

      Lookalike::Report.new(config.output_dir).write
      names = JSON.parse(File.read(File.join(config.output_dir, "results.json"))).map { |entry| entry.fetch("name") }
      expect(names.sort).to eq(%w[a/b a_b])
    ensure
      Lookalike.instance_variable_set(:@config, previous)
      ENV["LOOKALIKE_UPDATE"] = previous_update
    end
  end

  it "ignores only intermediate antialiasing pixels on a contrasting edge" do
    expected = Tessel::Image.new(3, 1, fill: "#ffffff")
    actual = expected.dup
    expected[0, 0] = [0, 0, 0, 255]
    expected[1, 0] = [128, 128, 128, 255]
    actual[0, 0] = [0, 0, 0, 255]
    expect(Lookalike.compare(expected, actual, threshold: 0.1).match?).to be(false)
    ignored = Lookalike.compare(expected, actual, threshold: 0.1, ignore_antialiasing: true)
    expect(ignored.match?).to be(true)
    expect(ignored.diff_image[1, 0]).to eq([255, 220, 0, 255])

    expected[1, 0] = [0, 0, 0, 255]
    expect(Lookalike.compare(expected, actual, threshold: 0.1, ignore_antialiasing: true).match?).to be(false)
  end

  it "writes a self-contained report with relative nested image paths" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "nested", "sample.actual.png")
      FileUtils.mkdir_p(File.dirname(path))
      Tessel::Image.new(1, 1).write(path)
      html = File.read(Lookalike::Report.new(dir).write)
      expect(html).to include("nested/sample.actual.png", "nested/sample.expected.png", "type='range'", "clipPath")
    end
  end
end
