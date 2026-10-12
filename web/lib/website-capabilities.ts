// The same list the database enforces (the websites capability check); the database refuses anything else.
export const CAPABILITIES = ['divisions.read', 'services.read', 'vacancies.read', 'team.read', 'statistics.read', 'portfolio.read', 'documents.read', 'enquiries.submit', 'applications.submit'] as const;
