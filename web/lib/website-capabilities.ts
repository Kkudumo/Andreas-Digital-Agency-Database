// The same list the database enforces (the websites capability check); the database refuses anything else.
export const CAPABILITIES = ['divisions.read', 'services.read', 'vacancies.read', 'team.read', 'statistics.read', 'portfolio.read', 'documents.read', 'content.read', 'settings.read', 'enquiries.submit', 'applications.submit'] as const;

/** What a website can ask to be told about (the events the database emits). */
export const EVENT_TYPES = ['service.published', 'service.unpublished', 'price.changed', 'content_post.published', 'content_post.unpublished', 'testimonial.published', 'testimonial.unpublished', 'faq.published', 'faq.unpublished', 'settings.changed'] as const;
