export default function RouteFallback() {
	return (
		<div
			className="flex min-h-[40vh] items-center justify-center bg-brand-900 text-mint-500"
			role="status"
			aria-busy="true"
			aria-label="Loading"
		>
			<div className="h-10 w-10 animate-spin rounded-full border-2 border-mint-500 border-t-transparent" />
		</div>
	);
}
