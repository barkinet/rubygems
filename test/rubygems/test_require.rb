require 'rubygems/test_case'
require 'rubygems'

class TestGemRequire < Gem::TestCase
  class Latch
    def initialize count = 1
      @count = count
      @lock  = Monitor.new
      @cv    = @lock.new_cond
    end

    def release
      @lock.synchronize do
        @count -= 1 if @count > 0
        @cv.broadcast if @count.zero?
      end
    end

    def await
      @lock.synchronize do
        @cv.wait_while { @count > 0 }
      end
    end
  end

  def setup
    super

    @old_loaded_features = $LOADED_FEATURES.dup
    assert_raises LoadError do
      require 'test_gem_require_a'
    end
    $LOADED_FEATURES.replace @old_loaded_features
  end

  def assert_require(path)
    assert require(path), "'#{path}' was already required"
  end

  def append_latch spec
    dir = spec.gem_dir
    Dir.chdir dir do
      spec.files.each do |file|
        File.open file, 'a' do |fp|
          fp.puts "FILE_ENTERED_LATCH.release"
          fp.puts "FILE_EXIT_LATCH.await"
        end
      end
    end
  end

  # Providing -I on the commandline should always beat gems
  def test_dash_i_beats_gems
    a1 = new_spec "a", "1", {"b" => "= 1"}, "lib/test_gem_require_a.rb"
    b1 = new_spec "b", "1", {"c" => "> 0"}, "lib/b/c.rb"
    c1 = new_spec "c", "1", nil, "lib/c/c.rb"
    c2 = new_spec "c", "2", nil, "lib/c/c.rb"

    install_specs c1, c2, b1, a1

    dir = Dir.mktmpdir
    dash_i_arg = File.join Dir.mktmpdir, 'lib'

    c_rb = File.join dash_i_arg, 'b', 'c.rb'

    FileUtils.mkdir_p File.dirname c_rb
    File.open(c_rb, 'w') { |f| f.write "class Object; HELLO = 'world' end" }

    lp = $LOAD_PATH.dup

    # Pretend to provide a commandline argument that overrides a file in gem b
    $LOAD_PATH.unshift dash_i_arg

    assert_require 'test_gem_require_a'
    assert_require 'b/c' # this should be required from -I
    assert_equal "world", ::Object::HELLO
  ensure
    $LOAD_PATH.replace lp
    Object.send :remove_const, :HELLO if Object.const_defined? :HELLO
  end

  def test_concurrent_require
    Object.const_set :FILE_ENTERED_LATCH, Latch.new(2)
    Object.const_set :FILE_EXIT_LATCH, Latch.new(1)

    a1 = new_spec "a", "1", nil, "lib/a.rb"
    b1 = new_spec "b", "1", nil, "lib/b.rb"

    install_specs a1, b1

    append_latch a1
    append_latch b1

    t1 = Thread.new { assert_require 'a' }
    t2 = Thread.new { assert_require 'b' }

    # wait until both files are waiting on the exit latch
    FILE_ENTERED_LATCH.await

    # now let them finish
    FILE_EXIT_LATCH.release

    assert t1.join, "thread 1 should exit"
    assert t2.join, "thread 2 should exit"
  ensure
    Object.send :remove_const, :FILE_ENTERED_LATCH
    Object.send :remove_const, :FILE_EXIT_LATCH
  end

  def test_require_is_not_lazy_with_exact_req
    a1 = new_spec "a", "1", {"b" => "= 1"}, "lib/test_gem_require_a.rb"
    b1 = new_spec "b", "1", nil, "lib/b/c.rb"
    b2 = new_spec "b", "2", nil, "lib/b/c.rb"

    install_specs b1, b2, a1

    assert_require 'test_gem_require_a'
    assert_equal %w(a-1 b-1), loaded_spec_names
    assert_equal unresolved_names, []

    assert_require "b/c"
    assert_equal %w(a-1 b-1), loaded_spec_names
  end

  def test_require_is_lazy_with_inexact_req
    a1 = new_spec "a", "1", {"b" => ">= 1"}, "lib/test_gem_require_a.rb"
    b1 = new_spec "b", "1", nil, "lib/b/c.rb"
    b2 = new_spec "b", "2", nil, "lib/b/c.rb"

    install_specs b1, b2, a1

    assert_require 'test_gem_require_a'
    assert_equal %w(a-1), loaded_spec_names
    assert_equal unresolved_names, ["b (>= 1)"]

    assert_require "b/c"
    assert_equal %w(a-1 b-2), loaded_spec_names
  end

  def test_require_is_not_lazy_with_one_possible
    a1 = new_spec "a", "1", {"b" => ">= 1"}, "lib/test_gem_require_a.rb"
    b1 = new_spec "b", "1", nil, "lib/b/c.rb"

    install_specs b1, a1

    assert_require 'test_gem_require_a'
    assert_equal %w(a-1 b-1), loaded_spec_names
    assert_equal unresolved_names, []

    assert_require "b/c"
    assert_equal %w(a-1 b-1), loaded_spec_names
  end

  def test_require_can_use_a_pathname_object
    a1 = new_spec "a", "1", nil, "lib/test_gem_require_a.rb"

    install_specs a1

    assert_require Pathname.new 'test_gem_require_a'
    assert_equal %w(a-1), loaded_spec_names
    assert_equal unresolved_names, []
  end

  def test_activate_via_require_respects_loaded_files
    a1 = new_spec "a", "1", {"b" => ">= 1"}, "lib/test_gem_require_a.rb"
    b1 = new_spec "b", "1", nil, "lib/benchmark.rb"
    b2 = new_spec "b", "2", nil, "lib/benchmark.rb"

    install_specs b1, b2, a1

    require 'test_gem_require_a'
    assert_equal unresolved_names, ["b (>= 1)"]

    refute require('benchmark'), "benchmark should have already been loaded"

    # We detected that we should activate b-2, so we did so, but
    # then original_require decided "I've already got benchmark.rb" loaded.
    # This case is fine because our lazy loading is provided exactly
    # the same behavior as eager loading would have.

    assert_equal %w(a-1 b-2), loaded_spec_names
  end

  def test_already_activated_direct_conflict
    a1 = new_spec "a", "1", { "b" => "> 0" }
    b1 = new_spec "b", "1", { "c" => ">= 1" }, "lib/ib.rb"
    b2 = new_spec "b", "2", { "c" => ">= 2" }, "lib/ib.rb"
    c1 = new_spec "c", "1", nil, "lib/d.rb"
    c2 = new_spec("c", "2", nil, "lib/d.rb")

    install_specs c1, c2, b1, b2, a1

    a1.activate
    c1.activate
    assert_equal %w(a-1 c-1), loaded_spec_names
    assert_equal ["b (> 0)"], unresolved_names

    assert require("ib")

    assert_equal %w(a-1 b-1 c-1), loaded_spec_names
    assert_equal [], unresolved_names
  end

  def test_multiple_gems_with_the_same_path
    a1 = new_spec "a", "1", { "b" => "> 0", "x" => "> 0" }
    b1 = new_spec "b", "1", { "c" => ">= 1" }, "lib/ib.rb"
    b2 = new_spec "b", "2", { "c" => ">= 2" }, "lib/ib.rb"
    x1 = new_spec "x", "1", nil, "lib/ib.rb"
    x2 = new_spec "x", "2", nil, "lib/ib.rb"
    c1 = new_spec "c", "1", nil, "lib/d.rb"
    c2 = new_spec("c", "2", nil, "lib/d.rb")

    install_specs c1, c2, x1, x2, b1, b2, a1

    a1.activate
    c1.activate
    assert_equal %w(a-1 c-1), loaded_spec_names
    assert_equal ["b (> 0)", "x (> 0)"], unresolved_names

    e = assert_raises(Gem::LoadError) do
      require("ib")
    end

    assert_equal "ib found in multiple gems: b, x", e.message
  end

  def test_unable_to_find_good_unresolved_version
    a1 = new_spec "a", "1", { "b" => "> 0" }
    b1 = new_spec "b", "1", { "c" => ">= 2" }, "lib/ib.rb"
    b2 = new_spec "b", "2", { "c" => ">= 3" }, "lib/ib.rb"

    c1 = new_spec "c", "1", nil, "lib/d.rb"
    c2 = new_spec "c", "2", nil, "lib/d.rb"
    c3 = new_spec "c", "3", nil, "lib/d.rb"

    install_specs c1, c2, c3, b1, b2, a1

    a1.activate
    c1.activate
    assert_equal %w(a-1 c-1), loaded_spec_names
    assert_equal ["b (> 0)"], unresolved_names

    e = assert_raises(Gem::LoadError) do
      require("ib")
    end

    assert_equal "unable to find a version of 'b' to activate", e.message
  end

  def test_default_gem_only
    default_gem_spec = new_default_spec("default", "2.0.0.0",
                                        nil, "default/gem.rb")
    install_default_specs(default_gem_spec)
    assert_require "default/gem"
    assert_equal %w(default-2.0.0.0), loaded_spec_names
  end

  def test_default_gem_and_normal_gem
    default_gem_spec = new_default_spec("default", "2.0.0.0",
                                        nil, "default/gem.rb")
    install_default_specs(default_gem_spec)
    normal_gem_spec = new_spec("default", "3.0", nil,
                               "lib/default/gem.rb")
    install_specs(normal_gem_spec)
    assert_require "default/gem"
    assert_equal %w(default-3.0), loaded_spec_names
  end

  def loaded_spec_names
    Gem.loaded_specs.values.map(&:full_name).sort
  end

  def unresolved_names
    Gem::Specification.unresolved_deps.values.map(&:to_s).sort
  end
end
