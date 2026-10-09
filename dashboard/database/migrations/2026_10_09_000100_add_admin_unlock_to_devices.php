<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

/**
 * One pending "open admin" request per tablet, handed over on its next
 * heartbeat and then cleared. Expires if the tablet does not report in time.
 */
return new class extends Migration
{
    public function up(): void
    {
        Schema::table('devices', function (Blueprint $table) {
            $table->string('admin_unlock_id', 16)->nullable()->after('status_reported_at');
            $table->timestamp('admin_unlock_expires_at')->nullable()->after('admin_unlock_id');
        });
    }

    public function down(): void
    {
        Schema::table('devices', function (Blueprint $table) {
            $table->dropColumn(['admin_unlock_id', 'admin_unlock_expires_at']);
        });
    }
};
