<x-app-layout title="Audit log">
    <h1 class="mb-1 text-2xl font-black">Audit log</h1>
    <p class="muted mb-5">Every sign-in, configuration change, enrollment and coin box command.</p>
    <section class="card overflow-x-auto">
        <table class="w-full text-left text-sm">
            <thead class="text-xs uppercase tracking-wide text-zinc-500">
            <tr><th class="py-2">When</th><th>Who</th><th>Action</th><th>Site</th><th>Details</th><th>IP</th></tr>
            </thead>
            <tbody class="divide-y divide-zinc-100">
            @forelse ($logs as $log)
                <tr class="align-top">
                    <td class="py-2 whitespace-nowrap">{{ $log->created_at->timezone(config('app.display_timezone', 'Asia/Manila'))->format('M j, g:i A') }}</td>
                    <td>{{ $log->user?->username ?? 'device' }}</td>
                    <td class="font-semibold">{{ $log->action }}</td>
                    <td>{{ $siteNames[$log->site_id] ?? '' }}</td>
                    <td class="font-mono text-xs text-zinc-600">{{ $log->details ? json_encode($log->details, JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE) : '' }}</td>
                    <td class="text-xs text-zinc-500">{{ $log->ip }}</td>
                </tr>
            @empty
                <tr><td colspan="6" class="py-3 text-zinc-500">Nothing yet.</td></tr>
            @endforelse
            </tbody>
        </table>
        <div class="mt-3">{{ $logs->links() }}</div>
    </section>
</x-app-layout>
