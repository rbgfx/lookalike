<h1 align="center">Lookalike</h1>

<p align="center">Golden image comparison for Ruby graphics.</p>

<p align="center">
  <a href="https://rubygems.org/gems/lookalike"><img src="https://badge.fury.io/rb/lookalike.svg" alt="Gem Version"></a>
  <a href="https://rubygems.org/gems/lookalike"><img src="https://img.shields.io/gem/dt/lookalike?label=downloads" alt="Downloads"></a>
  <a href="https://www.ruby-lang.org/"><img src="https://img.shields.io/badge/ruby-%3E%3D3.1-CC342D?logo=ruby&amp;logoColor=white" alt="Ruby Version"></a>
  <a href="LICENSE.txt"><img src="https://img.shields.io/badge/license-MIT-750014.svg" alt="License"></a>
</p>

[Features](#features) · [Installation](#installation) · [Quick Start](#quick-start)

***

Lookalike turns rendered images into visual regression tests. It compares Tessel images, file paths, and framebuffer-like objects, then writes actionable diffs for failed snapshots.

## Features

- Channel and YIQ perceptual comparison modes.
- Per-pixel deltas, allowed-pixel limits, bounding boxes, and diff images.
- Optional antialiasing detection for cleaner UI and text snapshots.
- RSpec, Minitest, and Test::Unit assertion helpers.
- Snapshot approval flow for local development and CI.
- HTML reports with an expected/actual overlay slider.

## Installation

Add Lookalike to your Gemfile:

~~~ruby
gem "lookalike"
~~~

Then run:

~~~sh
bundle install
~~~

Or install the released gem:

~~~sh
gem install lookalike
~~~

### Requirements

- Ruby 3.1 or newer.
- Tessel is installed automatically as a runtime dependency.

## Quick Start

~~~ruby
require "lookalike"

actual = Tessel.read("actual.png")
result = Lookalike.compare("expected.png", actual, mode: :channel, max_delta: 1)
abort result.inspect unless result.match?
~~~

For snapshot assertions, include <code>Lookalike::Assertions</code> in the test
context:

~~~ruby
include Lookalike::Assertions

assert_snapshot(render_scene, "home")
~~~

Missing snapshots are pending locally. Approve them with:

~~~sh
LOOKALIKE_UPDATE=1 bundle exec rake
lookalike approve NAME
lookalike approve --all
lookalike report tmp/lookalike
~~~

Set <code>CI</code> to make missing snapshots fail.

## Development

~~~sh
bundle install
bundle exec rake verify
~~~

## Contributing

Bug reports and pull requests are welcome at [rbgfx/lookalike](https://github.com/rbgfx/lookalike).

## License

[MIT](LICENSE.txt)
