<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

/**
 * Vendo schema: a site is one coin box shared by up to 4 tablets (stations).
 * Ported from the original backend (001_init.sql) with station numbers added.
 */
return new class extends Migration
{
    public function up(): void
    {
        Schema::create('sites', function (Blueprint $table) {
            $table->id();
            $table->foreignId('owner_id')->constrained('users');
            $table->string('name', 100);
            // Attendant's choice of tablet for the next coins (dashboard side).
            $table->unsignedTinyInteger('selected_station')->nullable();
            $table->timestamp('selection_expires_at')->nullable();
            $table->unsignedInteger('selection_version')->default(0);
            // What the coin box last reported (the truth on the floor).
            $table->unsignedTinyInteger('reported_station')->nullable();
            $table->unsignedInteger('reported_ttl_s')->nullable();
            $table->unsignedInteger('held_pulses')->default(0);
            $table->timestamp('last_poll_at')->nullable();
            $table->timestamps();
            $table->index('owner_id');
        });

        // Every configuration change creates a new immutable version row.
        Schema::create('site_configs', function (Blueprint $table) {
            $table->id();
            $table->foreignId('site_id')->constrained();
            $table->unsignedInteger('version');
            $table->unsignedInteger('seconds_per_pulse');
            $table->text('allowed_packages');
            $table->unsignedInteger('local_loss_timeout_s');
            $table->unsignedInteger('controller_sync_interval_s');
            $table->foreignId('created_by')->nullable()->constrained('users');
            $table->timestamp('created_at');
            $table->unique(['site_id', 'version']);
        });

        Schema::create('devices', function (Blueprint $table) {
            $table->id();
            $table->foreignId('site_id')->constrained();
            $table->string('device_type', 16); // controller | phone
            $table->string('public_id', 32)->unique();
            $table->char('token_hash', 64);
            $table->string('name', 100);
            $table->string('hardware_id', 64)->nullable();
            $table->unsignedTinyInteger('station_no')->nullable(); // phones: tablet 1-4
            $table->timestamp('revoked_at')->nullable();
            $table->timestamp('last_seen_at')->nullable();
            $table->string('last_ip', 45)->nullable();
            $table->string('sw_version', 32)->nullable();
            $table->unsignedInteger('config_version_applied')->nullable();
            $table->text('status_json')->nullable();
            $table->string('status_boot_id', 16)->nullable();
            $table->unsignedBigInteger('status_uptime_ms')->nullable();
            $table->timestamp('status_reported_at')->nullable();
            $table->timestamps();
            $table->index('site_id');
        });

        Schema::create('enrollment_codes', function (Blueprint $table) {
            $table->id();
            $table->foreignId('site_id')->constrained();
            $table->string('device_type', 16);
            $table->unsignedTinyInteger('station_no')->nullable();
            $table->char('code_hash', 64)->unique();
            $table->foreignId('created_by')->constrained('users');
            $table->timestamp('created_at');
            $table->timestamp('expires_at');
            $table->timestamp('used_at')->nullable();
            $table->foreignId('used_by_device_id')->nullable()->constrained('devices');
        });

        Schema::create('coin_events', function (Blueprint $table) {
            $table->id();
            $table->foreignId('device_id')->constrained();
            $table->foreignId('site_id')->constrained();
            $table->unsignedTinyInteger('station_no')->default(1); // 0 = held (unassigned)
            $table->string('boot_id', 16);
            $table->unsignedInteger('seq');
            $table->string('event_type', 16);
            $table->unsignedInteger('session_no');
            $table->unsignedInteger('pulses')->default(0);
            $table->unsignedInteger('seconds_added')->default(0);
            $table->unsignedInteger('rate_version')->default(0);
            $table->unsignedInteger('remaining_after')->default(0);
            $table->unsignedBigInteger('device_uptime_ms');
            $table->unsignedBigInteger('command_id')->nullable();
            $table->timestamp('occurred_at');
            $table->timestamp('received_at');
            $table->unique(['device_id', 'boot_id', 'seq']);
            $table->index(['site_id', 'occurred_at']);
        });

        // Customer sessions per tablet ("sessions" is Laravel's login session table).
        Schema::create('kiosk_sessions', function (Blueprint $table) {
            $table->id();
            $table->foreignId('device_id')->constrained();
            $table->foreignId('site_id')->constrained();
            $table->unsignedTinyInteger('station_no')->default(1);
            $table->string('boot_id', 16);
            $table->unsignedInteger('session_no');
            $table->timestamp('started_at');
            $table->timestamp('last_credit_at');
            $table->timestamp('ended_at')->nullable();
            $table->string('end_reason', 32)->nullable();
            $table->unsignedInteger('total_pulses')->default(0);
            $table->unsignedInteger('total_seconds')->default(0);
            $table->unsignedInteger('credit_count')->default(0);
            $table->unique(['device_id', 'boot_id', 'station_no', 'session_no']);
            $table->index(['site_id', 'started_at']);
        });

        // Dashboard → coin box commands, delivered on /controller/poll until acknowledged.
        Schema::create('controller_commands', function (Blueprint $table) {
            $table->id();
            $table->foreignId('site_id')->constrained();
            $table->string('type', 16); // add_time | end_session | assign_held
            $table->unsignedTinyInteger('station_no');
            $table->unsignedInteger('seconds')->nullable();
            $table->foreignId('created_by')->nullable()->constrained('users');
            $table->timestamp('created_at');
            $table->timestamp('delivered_at')->nullable();
            $table->timestamp('applied_at')->nullable();
            $table->string('result', 32)->nullable();
            $table->index(['site_id', 'applied_at']);
        });

        Schema::create('audit_logs', function (Blueprint $table) {
            $table->id();
            $table->foreignId('user_id')->nullable()->constrained();
            $table->foreignId('site_id')->nullable()->constrained();
            $table->foreignId('device_id')->nullable()->constrained();
            $table->string('action', 64);
            $table->text('details')->nullable();
            $table->string('ip', 45)->nullable();
            $table->timestamp('created_at');
            $table->index(['site_id', 'created_at']);
            $table->index(['user_id', 'created_at']);
        });
    }

    public function down(): void
    {
        foreach (['audit_logs', 'controller_commands', 'kiosk_sessions', 'coin_events', 'enrollment_codes', 'devices', 'site_configs', 'sites'] as $t) {
            Schema::dropIfExists($t);
        }
    }
};
