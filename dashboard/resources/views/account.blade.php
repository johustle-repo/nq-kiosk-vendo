<x-app-layout title="Account">
    <h1 class="mb-5 text-2xl font-black">Account</h1>
    <section class="card max-w-lg">
        <p class="mb-4"><span class="font-semibold">{{ auth()->user()->name }}</span> <span class="muted">({{ auth()->user()->username }})</span></p>
        <h2 class="mb-3 text-lg font-black">Change password</h2>
        <form method="post" action="{{ route('account.password') }}" class="space-y-3">
            @csrf
            <label class="label">Current password
                <input name="current_password" type="password" required autocomplete="current-password" class="field">
            </label>
            <label class="label">New password (10+ characters, letters and numbers)
                <input name="password" type="password" required autocomplete="new-password" class="field">
            </label>
            <label class="label">Repeat new password
                <input name="password_confirmation" type="password" required autocomplete="new-password" class="field">
            </label>
            <button class="btn-primary">Change password</button>
            <p class="muted">Other browsers signed in as you are signed out.</p>
        </form>
    </section>
</x-app-layout>
