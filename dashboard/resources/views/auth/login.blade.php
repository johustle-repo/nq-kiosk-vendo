<x-guest-layout title="Sign in">
    <h1 class="mb-1 text-xl font-black">Administrator sign in</h1>
    <p class="muted mb-5">Manage your coin boxes and tablets.</p>
    <form method="post" action="{{ route('login') }}" class="space-y-4">
        @csrf
        <label class="label">Username
            <input name="username" value="{{ old('username') }}" required maxlength="64" autocomplete="username" autofocus class="field">
        </label>
        <label class="label">Password
            <input name="password" type="password" required autocomplete="current-password" class="field">
        </label>
        <button class="btn-primary w-full py-2.5">Sign in</button>
    </form>
</x-guest-layout>
