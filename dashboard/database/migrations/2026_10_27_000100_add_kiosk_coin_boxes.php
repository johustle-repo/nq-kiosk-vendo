<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

/**
 * One coin box per tablet. A coin box enrolled with a tablet number serves only
 * that tablet (its own station 1); one enrolled without a number is the shared
 * box of the original design (stations 1-4). Commands now name the coin box
 * they are for, and each kiosk coin box reports its own held coins.
 */
return new class extends Migration
{
    public function up(): void
    {
        Schema::table('controller_commands', function (Blueprint $table) {
            // Null on commands queued before this change: the shared coin box takes them.
            $table->foreignId('device_id')->nullable()->after('site_id')->constrained();
        });
        Schema::table('devices', function (Blueprint $table) {
            $table->unsignedInteger('held_pulses')->default(0)->after('station_no');
            $table->timestamp('last_poll_at')->nullable()->after('held_pulses');
        });
    }

    public function down(): void
    {
        Schema::table('controller_commands', function (Blueprint $table) {
            $table->dropConstrainedForeignId('device_id');
        });
        Schema::table('devices', function (Blueprint $table) {
            $table->dropColumn(['held_pulses', 'last_poll_at']);
        });
    }
};
