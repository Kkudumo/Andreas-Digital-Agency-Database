// What a website may ask ADA Core for. The database enforces the same list (websites_capabilities_check).
export const CAPABILITIES = [
  { key: 'divisions.read', label: 'Divisions' },
  { key: 'services.read', label: 'Services and prices' },
  { key: 'vacancies.read', label: 'Vacancies' },
  { key: 'portfolio.read', label: 'Portfolio' },
  { key: 'team.read', label: 'Team' },
  { key: 'statistics.read', label: 'Company figures' },
  { key: 'documents.read', label: 'Published documents' },
  { key: 'enquiries.submit', label: 'Contact and quote forms' },
  { key: 'applications.submit', label: 'Job applications' },
] as const;

export type KeyState = { key?: string; site?: string; error?: string };
