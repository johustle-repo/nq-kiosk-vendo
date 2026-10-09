<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

/**
 * One pending "enable 10 taps" request per tablet, handed over on its next
 * heartbeat and then cleared. The tablet keeps the gesture on until its
 * administrator locks the admin screen.
 */
return new class extends Migration
{
    public function up(): void
    {
        Schema::table('devices', function (Blueprint $table) {
            $table->timestamp('tap_admin_expires_at')->nullable()->after('admin_unlock_expires_at');
        });
    }

    public function down(): void
    {
        Schema::table('devices', function (Blueprint $table) {
            $table->dropColumn('tap_admin_expires_at');
        });
    }
};
