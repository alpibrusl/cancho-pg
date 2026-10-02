drop table if exists gen_posts;
drop table if exists gen_users;
create table gen_users (
    id serial primary key,
    name text not null,
    age int,
    active boolean not null default true,
    balance bigint not null default 0,
    joined timestamptz not null default '2024-05-06 07:08:09+00',
    nickname text
);
create table gen_posts (
    id serial primary key,
    user_id int not null references gen_users (id),
    title text not null
);
