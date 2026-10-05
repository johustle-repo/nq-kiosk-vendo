<!doctype html>
<html lang="en">
<head>
    <meta charset="utf-8">
    @if (request()->attributes->get('csp_policy'))
        <meta http-equiv="Content-Security-Policy" content="{{ request()->attributes->get('csp_policy') }}">
    @endif
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <meta name="robots" content="noindex, nofollow">
    <meta name="theme-color" content="#018E4E">
    <title>{{ $title ?? 'Sign in' }} · VeNdO Kiosk</title>
    <link rel="icon" type="image/png" href="{{ asset('favicon.png') }}">
    @vite(['resources/css/app.css', 'resources/js/app.js'])
</head>
<body class="flex min-h-screen items-center justify-center bg-canvas px-4 py-10 text-ink antialiased">
<div class="w-full max-w-md">
    <img src="{{ asset('images/vendo-logo.png') }}" alt="VeNdO — Jo-hustle Smart Android" class="mx-auto mb-6 h-24 w-auto">
    <div class="card">
        @if ($errors->any())
            <div class="mb-4 rounded-xl border border-red-200 bg-red-50 px-4 py-3 text-sm text-red-800">
                @foreach ($errors->all() as $e)<p>{{ $e }}</p>@endforeach
            </div>
        @endif
        {{ $slot }}
    </div>
</div>
</body>
</html>
