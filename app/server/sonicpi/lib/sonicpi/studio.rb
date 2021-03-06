#--
# This file is part of Sonic Pi: http://sonic-pi.net
# Full project source: https://github.com/samaaron/sonic-pi
# License: https://github.com/samaaron/sonic-pi/blob/master/LICENSE.md
#
# Copyright 2013, 2014, 2015, 2016 by Sam Aaron (http://sam.aaron.name).
# All rights reserved.
#
# Permission is granted for use, copying, modification, and
# distribution of modified versions of this work as long as this
# notice is included.
#++
require_relative "util"
require_relative "server"
require_relative "note"
require_relative "samplebuffer"

require 'set'
require 'fileutils'

module SonicPi
  class Studio

    class StudioCurrentlyRebootingError < StandardError ; end
    include Util

    attr_reader :synth_group, :fx_group, :mixer_group, :monitor_group, :mixer_id, :mixer_bus, :mixer, :rand_buf_id, :amp, :rebooting

    attr_accessor :cent_tuning

    def initialize(ports, msg_queue, state)
      @state = state
      @scsynth_port = ports[:scsynth_port]
      @scsynth_send_port = ports[:scsynth_send_port]
      @osc_cues_port = ports[:osc_cues_port]
      @osc_midi_port = ports[:osc_midi_port]
      @msg_queue = msg_queue
      @error_occured_mutex = Mutex.new
      @error_occurred_since_last_check = false
      @sample_sem = Mutex.new
      @reboot_mutex = Mutex.new
      @rebooting = false
      @cent_tuning = 0
      @sample_format = "int16"
      @paused = false
      @cached_buffer_dir = Dir.mktmpdir

      init_scsynth
      reset_server
      init_studio
      init_or_reset_midi
    end

    def init_or_reset_midi
      if @o2m_pid || @m2o_pid
        message "Resetting MIDI"
        kill_and_deregister_process @o2m_pid if @o2m_pid
        kill_and_deregister_process @m2o_pid if @m2o_pid
      else
        message "Initialising MIDI"
      end

      begin
        m2o_spawn_cmd = "'#{osmid_m2o_path}'" + " -o #{@osc_cues_port} -m 6"
        Kernel.puts "Studio - Spawning m2o with:"
        Kernel.puts "    #{m2o_spawn_cmd}"
        @m2o_pid = spawn(m2o_spawn_cmd, out: osmid_m2o_log_path, err: osmid_m2o_log_path)
        register_process(@m2o_pid)
      rescue Exception => e
        message "Error initialising MIDI inputs"
        STDERR.puts "Exception when starting osmid m2o"
        STDERR.puts e.message
        STDERR.puts e.backtrace.inspect
        STDERR.puts e.backtrace
      end

      begin
        o2m_spawn_cmd = "'#{osmid_o2m_path}'" + " -i #{@osc_midi_port} -O #{@osc_cues_port} -m 6"
        Kernel.puts "Studio - Spawning o2m with:"
        Kernel.puts "    #{o2m_spawn_cmd}"
        @o2m_pid = spawn(o2m_spawn_cmd, out: osmid_o2m_log_path, err: osmid_o2m_log_path)
        register_process(@o2m_pid)
      rescue Exception => e
        message "Error initialising MIDI outputs"
        STDERR.puts "Exception when starting osmid o2m"
        STDERR.puts e.message
        STDERR.puts e.backtrace.inspect
        STDERR.puts e.backtrace
      end
    end

    def init_scsynth
      @server = Server.new(@scsynth_port, @scsynth_send_port, @msg_queue, @state)
    end

    def init_studio
      @server.load_synthdefs(synthdef_path)
      @amp = [0.0, 1.0]
      @server.add_event_handler("/sonic-pi/amp", "/sonic-pi/amp") do |payload|
        @amp = [payload[2], payload[3]]
      end


      old_synthdefs = @loaded_synthdefs
      @loaded_synthdefs = Set.new

      (old_synthdefs || []).each do |s|
        message "Reloading synthdefs in #{unify_tilde_dir(s)}"
        internal_load_synthdefs(s, @server)
      end

      # load rand stream directly - ensuring it doesn't get considered as a 'sample'
      rand_buf = @server.buffer_alloc_read(buffers_path + "/rand-stream.wav")

      @sample_sem.synchronize do
        @buffers = {}
      end

      old_samples = @samples
      @samples = {}

      Thread.new do
        __system_thread_locals.set_local(:sonic_pi_local_thread_group, "Studio sample loader")
        Thread.current.priority = -10
        (old_samples || {}).each do |k, v|
          message "Reloading sample - #{unify_tilde_dir(k)}"
          internal_load_sample(k, @server)
        end
      end


      @recorders = {}
      @recording_mutex = Mutex.new

      rand_buf.wait_for_allocation
      @rand_buf_id = rand_buf.to_i
    end

    def error_occurred?
      @error_occured_mutex.synchronize do
        if @error_occurred_since_last_check
          @error_occurred_since_last_check = false
          return true
        else
          return false
        end
      end
    end

    def scsynth_info
      @server.scsynth_info
    end

    def allocate_buffer(name, duration_in_seconds=nil)
      check_for_server_rebooting!(:allocate_buffer)
      name = name.to_sym
      cached_buffer = @buffers[name]
      return [cached_buffer, true] if cached_buffer && (!duration_in_seconds || (cached_buffer.duration == duration_in_seconds))

      # we can't just return a cached buffer - so grab the semaphore and
      # let's play...
      @sample_sem.synchronize do
        cached_buffer = @buffers[name]
        return [cached_buffer, true] if cached_buffer && (!duration_in_seconds || (cached_buffer.duration == duration_in_seconds))

        duration_in_seconds ||= 8
        # our buffer has the same name but is of a different duration
        # therefore nuke it


        path = @cached_buffer_dir + "/#{name}.wav"
        # now actually allocate a new buffer and cache it
        sample_rate = @server.scsynth_info[:sample_rate]
        buffer_info = @server.buffer_alloc(duration_in_seconds * sample_rate, 2)
        buffer_info.wait_for_allocation
        buffer_info.path = path
        save_buffer!(buffer_info, path)
        @buffers[name] = buffer_info
        @server.buffer_free(cached_buffer) if cached_buffer
        return [buffer_info, false]
      end
    end

    def free_buffer(name)
      check_for_server_rebooting!(:free_buffer)
      name = name.to_sym

      if @buffers[name]
        @sample_sem.synchronize do
          if @buffers[name]
            @server.buffer_free(@buffers[name])
            @buffers.delete(name)
          end
        end
        return true
      end

      false
    end

    def load_synthdefs(path, server=@server)
      check_for_server_rebooting!(:load_synthdefs)
      internal_load_synthdefs(path, server)
    end

    def sample_loaded?(path)
      return true if path.is_a?(Buffer)
      path = File.expand_path(path)
      return @samples.has_key?(path)
    end

    def load_sample(path, server=@server)
      check_for_server_rebooting!(:load_sample)
      internal_load_sample(path, server)
    end

    def free_sample(paths, server=@server)
      check_for_server_rebooting!(:free_sample)
      @sample_sem.synchronize do
        paths.each do |p|
          p = File.expand_path(p)
          info = @samples[p]
          @samples.delete(p)
          server.buffer_free(info) if info
        end
      end
      :free
    end

    def free_all_samples(server=@server)
      check_for_server_rebooting!(:free_all_samples)
      @sample_sem.synchronize do
        @samples.each do |k, v|
          server.buffer_free(v)
        end
        @samples = {}
      end
    end


    def start_amp_monitor
      check_for_server_rebooting!(:start_amp_monitor)
      unless @amp_synth
        @amp_synth = @server.trigger_synth :head, @monitor_group, "sonic-pi-amp_stereo_monitor", {"bus" => 0}, true
      end
    end


    def trigger_synth(synth_name, group, args, info, now=false, t_minus_delta=false, pos=:tail )
      check_for_server_rebooting!(:trigger_synth)

      @server.trigger_synth(pos, group, synth_name, args, info, now, t_minus_delta)
    end

    def set_volume(vol, now=false, silent=false)
      check_for_server_rebooting!(:invert)
      @volume = vol
      message "Setting master volume to #{vol}" unless silent
      @server.node_ctl @mixer, {"pre_amp" => vol}, now
    end

    def mixer_invert_stereo(invert)
      check_for_server_rebooting!(:mixer_invert_stereo)
      # invert should be true or false
      invert_i = invert ? 1 : 0
      @server.node_ctl @mixer, {"invert_stereo" => invert_i}, true
    end

    def mixer_control(opts)
      check_for_server_rebooting!(:mixer_control)
      now = 0
      opts = opts.clone
      if opts[:now].is_a?(Numeric)
        now = opts[:now]
      else
        now = opts[:now] ? 1 : 0
      end
      opts.delete :now
      @server.node_ctl @mixer, opts, now
    end

    def mixer_reset
      check_for_server_rebooting!(:mixer_reset)
      info = Synths::SynthInfo.get_info(:main_mixer)
      mixer_control(info.slide_arg_defaults)
      mixer_control(info.arg_defaults)
    end

    def mixer_stereo_mode
      check_for_server_rebooting!(:mixer_stereo_mode)
      @server.node_ctl @mixer, {"force_mono" => 0}, true
    end

    def mixer_mono_mode
      check_for_server_rebooting!(:mixer_mono_mode)
      @server.node_ctl @mixer, {"force_mono" => 1}, true
    end

    def status
      check_for_server_rebooting!(:status)
      @server.status
    end

    def stop
      check_for_server_rebooting!(:stop)
      @server.clear_schedule
      @server.group_clear @synth_group
    end

    def new_group(position, target, name="")
      check_for_server_rebooting!(:new_group)
      @server.create_group(position, target, name)
    end

    def new_synth_group(id=-1)
      check_for_server_rebooting!(:new_synth_group)
      new_group(:tail, @synth_group, "Run-#{id}-Synths")
    end

    def new_fx_group(id=-1)
      check_for_server_rebooting!(:new_fx_group)
      new_group(:tail, @fx_group, "Run-#{id}-FX")
    end

    def new_fx_bus
      check_for_server_rebooting!(:new_fx_bus)
      @server.allocate_audio_bus
    end

    def control_delta
      @server.control_delta
    end

    def control_delta=(t)
      @server.control_delta = t
    end

    def recording?
      ! @recorders.empty?
    end

    def bit_depth=(depth)
      @sample_format = case depth
                       when 8
                         "int8"
                       when 16
                         "int16"
                       when 24
                         "int24"
                       when 32
                         "int32"
                       else
                         raise "Unknown recording bit depth: #{depth}.\nExpected one of 8, 16, 24 or 32."
                       end
    end

    def recording_start(path, bus=0)
      check_for_server_rebooting!(:recording_start)
      return false if @recorders[bus]
      @recording_mutex.synchronize do
        return false if @recorders[bus]
        bs = @server.buffer_stream_open(path, 65536, 2, "wav", @sample_format)
        s = @server.trigger_synth :head, @monitor_group, "sonic-pi-recorder", {"out-buf" => bs.to_i, "in_bus" => bus.to_i}, true
        @recorders[bus] = [bs, s]
        true
      end
    end

    def save_buffer!(buf, path)
      @server.buffer_write(buf, path, "wav", @sample_format)
    end

    def recording_stop(bus=0)
      check_for_server_rebooting!(:recording_stop)
      return false unless @recorders[bus]
      @recording_mutex.synchronize do
        return false unless @recorders[bus]
        bs, s = @recorders[bus]
        p = Promise.new
        s.on_destroyed do
          p.deliver! :completed
        end
        s.kill

        # Ensure we wait for the recording synth to have completed
        # before continuing
        p.get(5)
        bs.free
        @recorders.delete bus

        # ensure nodes are all paused if we are in a paused state
        @server.node_pause(0, true) if @paused

        true
      end
    end

    def shutdown
      @server_reboot.kill
      begin
        @server.shutdown
      rescue Exception
      end
    end

    def reboot
      # Important:
      # This method should only be called from the @server_rebooter
      # thread.
      return nil if @rebooting
      @reboot_mutex.synchronize do
        @rebooting = true
        message "Rebooting SuperCollider audio server. Please wait..."
#        @server.shutdown
        message "init_midi"
        begin
          init_or_reset_midi
        rescue Exception => e
          message "Error initialising MIDI"
          message e.message
          message e.backtrace.inspect
          message e.backtrace
        end

        begin
          reset_server
        rescue Exception => e
          message "Error resetting server"
          message e.message
          message e.backtrace.inspect
          message e.backtrace
        end

        begin
          init_studio
        rescue Exception => e
          message "Error initialising Studio"
          message e.message
          message e.backtrace.inspect
          message e.backtrace
        end

        message "SuperCollider audio studio ready."
        @rebooting = false
        true
      end
    end

    def pause(silent=false)
      @recording_mutex.synchronize do
        unless recording? || @paused
          @server.node_pause(0, true)
          message "Pausing SuperCollider audio studio" unless silent
        end
        @paused = true
      end
    end

    def start
      @recording_mutex.synchronize do
        if @paused
          @server.node_run(0, true)
          message "Resuming SuperCollider audio studio"
        end
        @paused = false
      end
    end

    private

    def check_for_server_rebooting!(msg=nil)
      if @rebooting
        message "Oops, already rebooting: #{msg}"
        log "Oops, already rebooting: #{msg}"
        raise StudioCurrentlyRebootingError if @rebooting
      end
    end

    def message(s)
      m = s.to_s
      log "Studio - #{m}"
      @msg_queue.push({:type => :info, :val => "Studio: #{m}"}) unless __system_thread_locals.get :sonic_pi_spider_silent
    end


    def reset_and_setup_groups_and_busses
      log "Studio - clearing scsynth"
      @server.clear_scsynth!

      log "Studio - allocating audio bus"
      @mixer_bus = @server.allocate_audio_bus

      log "Studio - Create Base Synth Groups"
      @mixer_group = @server.create_group(:head, 0, "STUDIO-MIXER")
      @fx_group = @server.create_group(:before, @mixer_group, "STUDIO-FX")
      @synth_group = @server.create_group(:before, @fx_group, "STUDIO-SYNTHS")
      @monitor_group = @server.create_group(:after, @mixer_group, "STUDIO-MONITOR")
    end

    def reset_server
      message "Resetting SuperCollider audio server"
      reset_and_setup_groups_and_busses
      start_mixer
      start_scope
    end

    def start_mixer
      #message "Starting mixer"
      # TODO create a way of swapping these on the fly:
      # set_mixer! :basic
      # set_mixer! :default
      log "Starting mixer"
      mixer_synth = raspberry_pi_1? ? "sonic-pi-basic_mixer" : "sonic-pi-mixer"
      @mixer = @server.trigger_synth(:head, @mixer_group, mixer_synth, {"in_bus" => @mixer_bus.to_i}, nil, true)
    end

    def start_scope
      log "Starting scope"
      scope_synth = "sonic-pi-scope"
      @scope = @server.trigger_synth(:head, @monitor_group, scope_synth, { "max_frames" => 1024 })
    end


    def internal_load_sample(path, server=@server)
      path = File.expand_path(path)
      return [@samples[path], true] if @samples[path]
      #message "Loading full sample path: #{path}"
      sample_info = nil
      @sample_sem.synchronize do
        return @samples[path] if @samples[path]
        raise "No sample exists with path:\n  #{unify_tilde_dir(path).inspect}" unless File.exist?(path) && !File.directory?(path)
        buf_info = server.buffer_alloc_read(path)
        sample_info = SampleBuffer.new(buf_info, path)
        @samples[path] = sample_info
      end

      [sample_info, false]
    end

    def internal_load_synthdefs(path, server=@server)
      @sample_sem.synchronize do
        server.load_synthdefs(path)
        @loaded_synthdefs << path
      end
    end

  end
end
