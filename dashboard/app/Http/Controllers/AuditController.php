<?php

namespace App\Http\Controllers;

use App\Models\AuditLog;
use Illuminate\Http\Request;
use Illuminate\View\View;

class AuditController extends Controller
{
    /** The administrator's own actions and everything on their sites. */
    public function index(Request $request): View
    {
        $user = $request->user();
        $siteIds = $user->sites()->pluck('id');
        $logs = AuditLog::with('user')
            ->where(fn ($q) => $q->where('user_id', $user->id)->orWhereIn('site_id', $siteIds))
            ->orderByDesc('id')->paginate(50);

        return view('audit', ['logs' => $logs, 'siteNames' => $user->sites()->pluck('name', 'id')]);
    }
}
