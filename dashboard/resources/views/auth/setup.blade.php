<x-guest-layout title="First-time setup">
    <h1 class="mb-1 text-xl font-black">First-time setup</h1>
    <p class="muted mb-5">Creates the database tables and the first administrator. Works only while
        <code>SETUP_TOKEN</code> is set in <code>.env</code> and no administrator exists.</p>
    <form method="post" action="{{ route('setup') }}" class="space-y-4">
        @csrf
        <label class="label">Setup token (from .env)
            <input name="setup_token" type="password" required autocomplete="off" class="field">
        </label>
        <label class="label">Your name
            <input name="name" value="{{ old('name') }}" required maxlength="100" class="field">
        </label>
        <label class="label">Username
            <input name="username" value="{{ old('username') }}" required maxlength="64" autocomplete="username" class="field">
        </label>
        <label class="label">Password (10+ characters, letters and numbers)
            <input name="password" type="password" required autocomplete="new-password" class="field">
        </label>
        <label class="label">Repeat password
            <input name="password_confirmation" type="password" required autocomplete="new-password" class="field">
        </label>
        <button class="btn-primary w-full py-2.5">Create administrator</button>
    </form>
</x-guest-layout>
