select tests.setup();
select tests.setup_hr();
select tests.bank_account('nad');
update finance_settings set vat_registered = true, vat_rate = 15, vat_number = 'VAT-NA-555';
insert into services (division_id, name, summary, description, status, published_at) select id, 'Website Development', 's', 'd', 'published', now() from divisions where key = 'web';
insert into tests.ids select 'svc:web', id from services where name = 'Website Development';
select tests.remember('p:web', tests.scalar('web_lead', $q$ select price_propose((select id from tests.ids where key = 'svc:web'), 5000, 'NAD', current_date, 'July list')::text $q$));
select tests.scalar('ceo', $q$ select (price_decide((select id from tests.ids where key = 'p:web'), true)).status::text $q$);
