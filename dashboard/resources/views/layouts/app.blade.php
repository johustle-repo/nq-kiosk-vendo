<!doctype html>
<html lang="en">
<head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <meta name="robots" content="noindex, nofollow">
    <meta name="theme-color" content="#018E4E">
    <title>{{ $title ?? 'Dashboard' }} · VeNdO Kiosk</title>
    <link rel="icon" type="image/png" href="{{ asset('favicon.png') }}">
    @vite(['resources/css/app.css', 'resources/js/app.js'])
</head>
<body class="min-h-screen bg-canvas text-ink antialiased">
<header class="border-t-4 border-brand bg-white shadow-sm">
    <div class="mx-auto flex max-w-7xl flex-wrap items-center justify-between gap-3 px-4 py-3">
        <a href="{{ route('sites.index') }}" class="flex items-center gap-3">
            <img src="{{ asset('images/vendo-logo.png') }}" alt="VeNdO — Jo-hustle Smart Android" class="h-9 w-auto">
            <span class="hidden text-sm font-semibold text-zinc-500 sm:inline">Admin</span>
        </a>
        @auth
            <nav class="flex flex-wrap items-center gap-1 text-sm font-semibold">
                <a href="{{ route('sites.index') }}" @class(['rounded-lg px-3 py-1.5', 'bg-brand-soft text-brand-deep' => request()->routeIs('sites.*'), 'text-charcoal hover:bg-zinc-100' => ! request()->routeIs('sites.*')])>Sites</a>
                <a href="{{ route('audit') }}" @class(['rounded-lg px-3 py-1.5', 'bg-brand-soft text-brand-deep' => request()->routeIs('audit'), 'text-charcoal hover:bg-zinc-100' => ! request()->routeIs('audit')])>Audit log</a>
                <a href="{{ route('account') }}" @class(['rounded-lg px-3 py-1.5', 'bg-brand-soft text-brand-deep' => request()->routeIs('account'), 'text-charcoal hover:bg-zinc-100' => ! request()->routeIs('account')])>{{ auth()->user()->username }}</a>
                <form method="post" action="{{ route('logout') }}">
                    @csrf
                    <button class="rounded-lg px-3 py-1.5 text-charcoal hover:bg-zinc-100">Sign out</button>
                </form>
            </nav>
        @endauth
    </div>
</header>

<main class="mx-auto max-w-7xl px-4 py-6">
    @if (session('status'))
        <div class="mb-4 rounded-xl border border-brand/30 bg-brand-soft px-4 py-3 text-sm font-semibold text-brand-deep">{{ session('status') }}</div>
    @endif
    @if ($errors->any())
        <div class="mb-4 rounded-xl border border-red-200 bg-red-50 px-4 py-3 text-sm text-red-800">
            <ul class="list-disc pl-5">@foreach ($errors->all() as $e)<li>{{ $e }}</li>@endforeach</ul>
        </div>
    @endif
    {{ $slot }}
</main>
</body>
</html>
