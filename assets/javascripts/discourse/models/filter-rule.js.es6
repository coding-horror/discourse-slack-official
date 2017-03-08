import RestModel from 'discourse/models/rest';

export default RestModel.extend({
  category_id: -1,
  channel: '',
  filter: null,

  category: function() {
    var id = this.get('category_id');

    switch (id) {
      case '*':
        return Discourse.Category.create({ name: I18n.t('slack.choose.all_categories'), id: '*' });
        break;
      default:
        if (id) {
          return Discourse.Category.create({ name: null, id: null });
        } else {
          return Discourse.Category.findById(id) || { id: id, name: 'Deleted Category' };
        }
    }
  }.property('category_id'),

  filter_name: function() {
    return I18n.t('slack.present.' + this.get('filter') );
  }.property('filter')

});
